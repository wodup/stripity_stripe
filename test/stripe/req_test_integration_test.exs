defmodule Stripe.ReqTestIntegrationTest do
  @moduledoc """
  Exercises the way consuming applications are expected to stub Stripe in their
  own test suites, by pointing `:req_options` at `Req.Test`.

  Synchronous, because `:req_options` is global configuration.
  """

  use Stripe.StripeCase

  setup do
    put_req_options(plug: {Req.Test, Stripe.API})
    :ok
  end

  test "a stubbed response is converted into a Stripe struct" do
    Req.Test.expect(Stripe.API, fn conn ->
      Req.Test.json(conn, %{"id" => "cus_123", "object" => "customer", "livemode" => false})
    end)

    assert {:ok, %Stripe.Customer{id: "cus_123", livemode: false}} =
             Stripe.Customer.retrieve("cus_123")
  end

  test "the stub receives the request the library would have sent" do
    Req.Test.expect(Stripe.API, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/customers"
      assert Enum.into(conn.req_headers, %{})["authorization"] == "Bearer sk_test_123"

      Req.Test.json(conn, %{"id" => "cus_456", "object" => "customer"})
    end)

    assert {:ok, %Stripe.Customer{id: "cus_456"}} =
             Stripe.Customer.create(%{email: "test@example.com"})
  end

  test "a stubbed error response is converted into a Stripe.Error" do
    Req.Test.expect(Stripe.API, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("request-id", "req_123")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, ~s({"error": {"type": "invalid_request_error"}}))
    end)

    assert {:error, %Stripe.Error{source: :stripe, request_id: "req_123"} = error} =
             Stripe.Customer.retrieve("cus_nope")

    assert error.extra.http_status == 404
  end

  test "a transport failure is converted into a network Stripe.Error" do
    put_retry_config(max_attempts: 0)

    Req.Test.expect(Stripe.API, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Stripe.Error{source: :network, code: :network_error} = error} =
             Stripe.Customer.retrieve("cus_123")

    assert error.extra.http_reason == :econnrefused
  end

  test "a retryable transport failure is retried" do
    put_retry_config(max_attempts: 1, base_backoff: 1, max_backoff: 1)

    Req.Test.expect(Stripe.API, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    Req.Test.expect(Stripe.API, fn conn ->
      Req.Test.json(conn, %{"id" => "cus_123", "object" => "customer"})
    end)

    assert {:ok, %Stripe.Customer{id: "cus_123"}} = Stripe.Customer.retrieve("cus_123")
  end

  test "a file upload is sent as a well formed multipart request" do
    path = Path.join(System.tmp_dir!(), "stripity_stripe_upload_test.txt")
    File.write!(path, "dispute evidence")
    on_exit(fn -> File.rm(path) end)

    Req.Test.expect(Stripe.API, fn conn ->
      assert ["multipart/form-data; boundary=" <> _] =
               Plug.Conn.get_req_header(conn, "content-type")

      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))

      assert conn.params["purpose"] == "dispute_evidence"
      assert %Plug.Upload{filename: "stripity_stripe_upload_test.txt"} = conn.params["file"]
      assert File.read!(conn.params["file"].path) == "dispute evidence"

      Req.Test.json(conn, %{"id" => "file_123", "object" => "file"})
    end)

    assert {:ok, %Stripe.FileUpload{id: "file_123"}} =
             Stripe.FileUpload.create(%{file: path, purpose: "dispute_evidence"})
  end

  defp put_retry_config(config), do: put_env(:retries, config)
end
