defmodule Stripe.APITest do
  import Mox
  use Stripe.StripeCase

  test "works with non existent responses without issue" do
    {:error, %Stripe.Error{extra: %{http_status: 404}}} =
      Stripe.API.request(%{}, :get, "/", %{}, [])
  end

  test "oauth_request works" do
    verify_on_exit!()

    Stripe.APIMock
    |> expect(:oauth_request, fn method, _endpoint, _body -> method end)

    assert Stripe.APIMock.oauth_request(:post, "www", %{body: "body"}) == :post
  end

  describe "generate_idempotency_key" do
    test "returns string value" do
      key = Stripe.API.generate_idempotency_key()

      assert key
      assert is_binary(key)
    end

    test "returns unique value" do
      key1 = Stripe.API.generate_idempotency_key()
      key2 = Stripe.API.generate_idempotency_key()

      assert key1 != key2
    end
  end

  describe "should_retry?" do
    test "given timeout error" do
      assert Stripe.API.should_retry?({:error, :timeout})
    end

    test "given connection timeout error" do
      assert Stripe.API.should_retry?({:error, :connect_timeout})
    end

    test "given connection refused error" do
      assert Stripe.API.should_retry?({:error, :econnrefused})
    end

    test "given HTTP 429 response" do
      assert Stripe.API.should_retry?({:ok, 429, [], ""})
    end

    test "given a stale pooled connection" do
      assert Stripe.API.should_retry?({:error, :invalid_state})
    end

    test "given a connection closed mid-request" do
      assert Stripe.API.should_retry?({:error, :closed})
    end

    test "given other error" do
      refute Stripe.API.should_retry?({:error, :unknown})
    end

    test "given HTTP 200 response" do
      refute Stripe.API.should_retry?({:ok, 200, [], ""})
    end

    test "given HTTP 500 response" do
      assert Stripe.API.should_retry?({:ok, 500, [], ""})
    end

    test "given HTTP 503 response" do
      assert Stripe.API.should_retry?({:ok, 503, [], ""})
    end

    test "given HTTP 400 response" do
      refute Stripe.API.should_retry?({:ok, 400, [], ""})
    end

    test "given Stripe-Should-Retry false on an otherwise retryable status" do
      refute Stripe.API.should_retry?({:ok, 429, %{"stripe-should-retry" => ["false"]}, ""})
    end

    test "given Stripe-Should-Retry true on an otherwise final status" do
      assert Stripe.API.should_retry?({:ok, 400, %{"stripe-should-retry" => ["true"]}, ""})
    end

    test "defaults to five retries" do
      assert Stripe.API.should_retry?({:error, :timeout}, 4)
      refute Stripe.API.should_retry?({:error, :timeout}, 5)
    end

    test "given attempts greater than max_attempts" do
      refute Stripe.API.should_retry?({:error, :timeout}, 2, max_attempts: 1)
    end

    test "given attempts less than max_attempts" do
      assert Stripe.API.should_retry?({:error, :timeout}, 0, max_attempts: 1)
    end

    test "given attempts equals to max_attempts" do
      refute Stripe.API.should_retry?({:error, :timeout}, 1, max_attempts: 1)
    end
  end

  describe "backoff" do
    test "given attempts = 0" do
      backoff = Stripe.API.backoff(0, base_backoff: 10, max_backoff: 100)
      assert backoff == 10
    end

    test "given attempts = 1" do
      backoff = Stripe.API.backoff(1, base_backoff: 10, max_backoff: 100)
      assert backoff in 10..20
    end

    test "given attempts = 2" do
      backoff = Stripe.API.backoff(2, base_backoff: 10, max_backoff: 100)
      assert backoff in 20..40
    end
  end

  test "gets default api version" do
    Stripe.API.request(%{}, :get, "products", %{}, [])
    assert_stripe_requested(:get, "/v1/products", headers: {"Stripe-Version", "2019-12-03"})
  end

  test "can set custom api version" do
    Stripe.API.request(%{}, :get, "products", %{},
      api_version: "2019-05-16; checkout_sessions_beta=v1"
    )

    assert_stripe_requested(:get, "/v1/products",
      headers: {"Stripe-Version", "2019-05-16; checkout_sessions_beta=v1"}
    )
  end

  test "oauth_request sets authorization header for deauthorize request" do
    # Echo the request headers back as the response body. OAuth requests go to
    # connect.stripe.com rather than the mock server, so they are stubbed out.
    Req.Test.stub(Stripe.API, fn conn ->
      Req.Test.json(conn, Enum.into(conn.req_headers, %{}))
    end)

    put_req_options(plug: {Req.Test, Stripe.API})

    {:ok, body} = Stripe.API.oauth_request(:post, "deauthorize", %{})
    assert body["authorization"] == "Bearer sk_test_123"

    {:ok, body} = Stripe.API.oauth_request(:post, "deauthorize", %{}, "1234")
    assert body["authorization"] == "Bearer 1234"

    {:ok, body} = Stripe.API.oauth_request(:post, "token", %{})
    refute Map.has_key?(body, "authorization")
  end

  describe "pool_options config" do
    test "maps to the Finch equivalents" do
      put_env(:pool_options, timeout: 15_000, max_connections: 25, connect_timeout: 3_000)

      assert [{Finch, finch_opts}] = Stripe.API.supervisor_children()
      pool = finch_opts[:pools][:default]

      assert pool[:size] == 25
      assert pool[:conn_opts] == [transport_opts: [timeout: 3_000]]

      # `:timeout` is a per-connection idle timeout, so it must not be mapped to
      # `:pool_max_idle_time`, which terminates the whole pool.
      assert pool[:conn_max_idle_time] == 15_000
      refute Keyword.has_key?(pool, :pool_max_idle_time)
    end

    test "omits conn_opts when no connect timeout is configured" do
      put_env(:pool_options, timeout: 5_000, max_connections: 10)

      assert [{Finch, finch_opts}] = Stripe.API.supervisor_children()
      refute Keyword.has_key?(finch_opts[:pools][:default], :conn_opts)
    end
  end

  describe "req_options config" do
    test "is not applied when unset" do
      Stripe.API.request(%{}, :get, "products", %{}, [])

      assert_received({_method, _url, _headers, _body, opts})
      refute Map.has_key?(opts, :receive_timeout)
      refute Map.has_key?(opts, :connect_options)
    end

    test "is passed through to Req" do
      put_req_options(receive_timeout: 5_000, connect_options: [timeout: 1_000])

      Stripe.API.request(%{}, :get, "products", %{}, [])

      assert_received({_method, _url, _headers, _body, opts})
      assert opts[:receive_timeout] == 5_000
      assert opts[:connect_options] == [timeout: 1_000]
    end

    test "is overridden by per-request options" do
      put_req_options(receive_timeout: 5_000)

      Stripe.API.request(%{}, :get, "products", %{}, receive_timeout: 250)

      assert_received({_method, _url, _headers, _body, opts})
      assert opts[:receive_timeout] == 250
    end
  end
end
