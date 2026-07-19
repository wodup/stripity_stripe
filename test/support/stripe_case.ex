defmodule Stripe.StripeCase do
  @moduledoc """
  This module defines the setup for tests requiring access to a mocked version of Stripe.
  """

  use ExUnit.CaseTemplate

  def assert_stripe_requested(expected_method, path, extra \\ []) do
    expected_url = build_url(path, Keyword.get(extra, :query))
    expected_body = Keyword.get(extra, :body)
    expected_headers = Keyword.get(extra, :headers)

    assert_received({method, url, headers, body, _})

    assert expected_method == method
    assert expected_url == url

    assert_stripe_request_body(expected_body, body)
    assert_stripe_request_headers(expected_headers, headers)
  end

  def stripe_base_url() do
    Application.get_env(:stripity_stripe, :api_base_url)
  end

  defp assert_stripe_request_headers(nil, _), do: nil

  defp assert_stripe_request_headers(expected_headers, headers) when is_list(expected_headers) do
    assert Enum.all?(expected_headers, &assert_stripe_request_headers(&1, headers))
  end

  defp assert_stripe_request_headers({expected_name, expected_value}, headers) do
    expected = {String.downcase(expected_name), expected_value}

    assert Enum.any?(headers, fn header -> expected == header end),
           """
           Expected the header `#{inspect(expected)}` to be in the headers of the request.

           Headers:
           #{inspect(headers)}
           """
  end

  defp assert_stripe_request_body(nil, _), do: nil

  defp assert_stripe_request_body(expected_body, body) do
    assert body == Stripe.URI.encode_query(expected_body)
  end

  defp build_url("/v1/" <> path, nil) do
    stripe_base_url() <> path
  end

  defp build_url("/v1/" <> path, query_params) do
    stripe_base_url() <> path <> "?" <> URI.encode_query(query_params)
  end

  @doc """
  Hooks into Req's `:finch_request` option to report each outgoing request to
  the owning process, so that `assert_stripe_requested/3` can assert on it, and
  then performs the request as Req normally would.

  This runs after every request step has been applied, so the recorded headers
  and body are exactly what goes over the wire. Headers are flattened to
  `{downcased_name, value}` tuples, since Req carries them as a map of
  name => list of values.
  """
  def report_and_run(%Req.Request{} = request, finch_request, finch_name, finch_options) do
    headers =
      Enum.flat_map(request.headers, fn {name, values} ->
        Enum.map(List.wrap(values), &{name, &1})
      end)

    send(
      self(),
      {request.method, URI.to_string(request.url), headers, request.body, request.options}
    )

    result =
      case Finch.request(finch_request, finch_name, finch_options) do
        {:ok, response} -> Req.Response.new(response)
        {:error, exception} -> exception
      end

    {request, result}
  end

  @doc """
  The Req options every test runs with.
  """
  def default_req_options do
    [finch_request: &__MODULE__.report_and_run/4]
  end

  @doc """
  Merges `options` into the configured Req options for the duration of the
  current test, restoring the previous value afterwards.

  Only safe from synchronous test cases, since the configuration is global.
  """
  def put_req_options(options) do
    put_env(:req_options, Keyword.merge(default_req_options(), options))
  end

  @doc """
  Sets `key` in the application environment for the duration of the current
  test, restoring the previous value afterwards.

  A key that was previously unset is deleted rather than set to `nil`, so that
  `Application.get_env/3` falls back to its default as it did before.

  Only safe from synchronous test cases, since the configuration is global.
  """
  def put_env(key, value) do
    previous = Application.fetch_env(:stripity_stripe, key)
    Application.put_env(:stripity_stripe, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(:stripity_stripe, key, previous)
        :error -> Application.delete_env(:stripity_stripe, key)
      end
    end)
  end

  using do
    quote do
      import Stripe.StripeCase,
        only: [
          assert_stripe_requested: 2,
          assert_stripe_requested: 3,
          stripe_base_url: 0,
          put_req_options: 1,
          put_env: 2
        ]

      Application.put_env(
        :stripity_stripe,
        :req_options,
        Stripe.StripeCase.default_req_options()
      )
    end
  end
end
