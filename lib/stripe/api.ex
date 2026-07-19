defmodule Stripe.API do
  @moduledoc """
  Low-level utilities for interacting with the Stripe API.

  Usually the utilities in `Stripe.Request` are a better way to write custom interactions with
  the API.
  """
  alias Stripe.{Config, Error}

  @callback oauth_request(method, String.t(), map) :: {:ok, map}

  @type method :: :get | :post | :put | :delete | :patch
  @type headers :: %{String.t() => String.t()} | %{}
  @type body :: iodata() | {:multipart, list()}
  @typep http_success :: {:ok, integer, %{String.t() => [String.t()]}, String.t()}
  @typep http_failure :: {:error, term}

  @finch_name __MODULE__.Finch
  @api_version "2019-12-03"

  @idempotency_key_header "Idempotency-Key"

  @default_max_attempts 5
  @default_base_backoff 500
  @default_max_backoff 2_000
  @default_max_retry_after 60_000

  @doc """
  In config.exs your implicit or expicit configuration is:
    config :stripity_stripe,
      json_library: Poison # defaults to Jason but can be configured to Poison
  """
  @spec json_library() :: module
  def json_library() do
    Config.resolve(:json_library, Jason)
  end

  def supervisor_children do
    if use_pool?() do
      [{Finch, name: @finch_name, pools: %{default: finch_pool_options()}}]
    else
      []
    end
  end

  # Translates the library's historical (hackney-derived) `:pool_options` into
  # their Finch equivalents:
  #
  #   * `:max_connections`  – connections held per origin -> Finch's `:size`
  #   * `:timeout`          – how long an idle connection is kept before being
  #                           closed -> Finch's `:conn_max_idle_time`
  #   * `:connect_timeout`  – how long to wait when establishing a connection
  #                           -> Finch's `:conn_opts`
  #
  # `:timeout` maps to `:conn_max_idle_time` rather than `:pool_max_idle_time`:
  # the former closes an individual connection that has sat idle too long, which
  # is what hackney's pool timeout did and what keeps a stale keep-alive socket
  # from being handed out. The latter terminates the whole pool, which Finch
  # warns causes pool restarts at low values.
  @spec finch_pool_options() :: Keyword.t()
  defp finch_pool_options() do
    opts = get_pool_options() || []

    [
      size: Keyword.get(opts, :max_connections, 10),
      conn_max_idle_time: Keyword.get(opts, :timeout, 5_000)
    ]
    |> put_conn_opts(Keyword.get(opts, :connect_timeout))
  end

  @spec put_conn_opts(Keyword.t(), non_neg_integer | nil) :: Keyword.t()
  defp put_conn_opts(pool_options, nil), do: pool_options

  defp put_conn_opts(pool_options, connect_timeout) do
    Keyword.put(pool_options, :conn_opts, transport_opts: [timeout: connect_timeout])
  end

  @spec get_pool_options() :: Keyword.t()
  defp get_pool_options() do
    Config.resolve(:pool_options)
  end

  @spec get_base_url() :: String.t()
  defp get_base_url() do
    Config.resolve(:api_base_url)
  end

  @spec get_upload_url() :: String.t()
  defp get_upload_url() do
    Config.resolve(:api_upload_url)
  end

  @spec get_default_api_key() :: String.t()
  defp get_default_api_key() do
    # if no API key is set default to `""` which will raise a Stripe API error
    Config.resolve(:api_key, "")
  end

  @spec get_api_version() :: String.t()
  defp get_api_version() do
    Config.resolve(:api_version, @api_version)
  end

  @spec use_pool?() :: boolean
  defp use_pool?() do
    Config.resolve(:use_connection_pool)
  end

  # Options merged into every `Req` request the library makes.
  #
  # Anything `Req` accepts is valid here, which is also the supported way to
  # inject a test stub:
  #
  #     config :stripity_stripe,
  #       req_options: [plug: {Req.Test, Stripe.API}]
  #
  @spec req_options() :: Keyword.t()
  defp req_options() do
    case Config.resolve(:req_options, []) do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end

  @spec retry_config() :: Keyword.t()
  defp retry_config() do
    Config.resolve(:retries, [])
  end

  @doc """
  Checks if an error is a problem that we should retry on. This includes both
  socket errors that may represent an intermittent problem and some special
  HTTP statuses.
  """
  @spec should_retry?(
          http_success | http_failure,
          attempts :: non_neg_integer,
          config :: Keyword.t()
        ) :: boolean
  def should_retry?(response, attempts \\ 0, config \\ []) do
    max_attempts = Keyword.get(config, :max_attempts) || @default_max_attempts

    if attempts >= max_attempts do
      false
    else
      retry_response?(response)
    end
  end

  @doc """
  A low level utility function to generate a new idempotency key for
  `#{@idempotency_key_header}` request header value.
  """
  @spec generate_idempotency_key() :: binary
  def generate_idempotency_key do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      System.unique_integer([:positive])::32
    >>

    Base.hex_encode32(binary, case: :lower, padding: false)
  end

  # `Accept-Encoding` and `Connection` are deliberately not set here: Req sets
  # `Accept-Encoding` from the `:compressed` option in `build_req_options/1` and
  # decompresses the response to match, and Finch owns connection reuse.
  @spec add_common_headers(headers) :: headers
  defp add_common_headers(existing_headers) do
    Map.merge(existing_headers, %{
      "Accept" => "application/json; charset=utf8"
    })
  end

  # Multipart requests intentionally carry no `Content-Type`: Req generates it,
  # along with the boundary, when it encodes the `:form_multipart` body.
  @spec add_default_headers(headers, body) :: headers
  defp add_default_headers(existing_headers, {:multipart, _parts}) do
    existing_headers
    |> add_common_headers()
    |> Map.delete("Content-Type")
  end

  defp add_default_headers(existing_headers, _body) do
    existing_headers = add_common_headers(existing_headers)

    case Map.has_key?(existing_headers, "Content-Type") do
      false -> existing_headers |> Map.put("Content-Type", "application/x-www-form-urlencoded")
      true -> existing_headers
    end
  end

  @spec add_idempotency_headers(headers, method) :: headers
  defp add_idempotency_headers(existing_headers, method) when method in [:get, :head] do
    existing_headers
  end

  defp add_idempotency_headers(existing_headers, _method) do
    # By using `Map.put_new/3` instead of `Map.put/3`, we allow users to
    # provide their own idempotency key.
    existing_headers
    |> Map.put_new(@idempotency_key_header, generate_idempotency_key())
  end

  @spec maybe_add_auth_header_oauth(headers, String.t(), String.t() | nil) :: headers
  defp maybe_add_auth_header_oauth(headers, "deauthorize", api_key),
    do: add_auth_header(headers, api_key)

  defp maybe_add_auth_header_oauth(headers, _endpoint, _api_key), do: headers

  @spec add_auth_header(headers, String.t() | nil) :: headers
  defp add_auth_header(existing_headers, api_key) do
    api_key = fetch_api_key(api_key)
    Map.put(existing_headers, "Authorization", "Bearer #{api_key}")
  end

  @spec fetch_api_key(String.t() | nil) :: String.t()
  defp fetch_api_key(api_key) do
    case api_key do
      key when is_binary(key) -> key
      _ -> get_default_api_key()
    end
  end

  @spec add_connect_header(headers, String.t() | nil) :: headers
  defp add_connect_header(existing_headers, nil), do: existing_headers

  defp add_connect_header(existing_headers, account_id) do
    Map.put(existing_headers, "Stripe-Account", account_id)
  end

  @spec add_api_version(headers, String.t() | nil) :: headers
  defp add_api_version(existing_headers, nil),
    do: add_api_version(existing_headers, get_api_version())

  defp add_api_version(existing_headers, api_version) do
    Map.merge(existing_headers, %{
      "User-Agent" => "Stripe/v1 stripity-stripe/#{api_version}",
      "Stripe-Version" => api_version
    })
  end

  # Options every request is built with.
  #
  #   * `:decode_body` is disabled because responses are decoded with the
  #     configured `json_library/0`, which callers may override. Decompression
  #     is a separate step and stays enabled.
  #   * `:retry` is disabled in favour of the library's own retry policy - see
  #     `should_retry?/3` and `backoff/2`.
  #   * `:redirect` is disabled because the Stripe API does not redirect, and
  #     following one silently would turn an anomalous response into an
  #     apparently successful request. A 3xx surfaces as a `Stripe.Error`.
  #   * `:compressed` is enabled so Req sets `Accept-Encoding` and decompresses
  #     the response. It defaults to `false`, so without this responses would
  #     come back uncompressed.
  #
  # Per-request options win over the `:req_options` config, which in turn wins
  # over these defaults.
  @spec build_req_options(list) :: Keyword.t()
  defp build_req_options(opts) do
    [decode_body: false, retry: false, redirect: false, compressed: true]
    |> Keyword.merge(req_options())
    |> Keyword.merge(opts)
    |> add_finch_option()
  end

  # Req refuses to combine a named Finch instance with `:connect_options`,
  # since the latter makes it build and supervise a pool of its own. Connection
  # tuning for the library's pool belongs in `:pool_options` instead, so an
  # explicit `:connect_options` is taken as a deliberate opt out of that pool.
  @spec add_finch_option(Keyword.t()) :: Keyword.t()
  defp add_finch_option(opts) do
    if use_pool?() and not Keyword.has_key?(opts, :connect_options) do
      Keyword.put(opts, :finch, @finch_name)
    else
      opts
    end
  end

  @doc """
  A low level utility function to make a direct request to the Stripe API

  ## Setting the api key

      request(%{}, :get, "/customers", %{}, api_key: "bogus key")

  ## Setting api version

  The api version defaults to #{@api_version} but a custom version can be passed
  in as follows:

      request(%{}, :get, "/customers", %{}, api_version: "2018-11-04")

  ## Connect Accounts

  If you'd like to make a request on behalf of another Stripe account
  utilizing the Connect program, you can pass the other Stripe account's
  ID to the request function as follows:

      request(%{}, :get, "/customers", %{}, connect_account: "acc_134151")

  """
  @spec request(body, method, String.t(), headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def request(body, :get, endpoint, headers, opts) do
    {expansion, opts} = Keyword.pop(opts, :expand)
    base_url = get_base_url()

    req_url =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> add_object_expansion(expansion)
      |> Stripe.URI.encode_query()
      |> prepend_url("#{base_url}#{endpoint}")

    perform_request(req_url, :get, "", headers, opts)
  end

  def request(body, method, endpoint, headers, opts) do
    {expansion, opts} = Keyword.pop(opts, :expand)
    {idempotency_key, opts} = Keyword.pop(opts, :idempotency_key)

    base_url = get_base_url()
    req_url = add_object_expansion("#{base_url}#{endpoint}", expansion)
    headers = add_idempotency_header(idempotency_key, headers, method)

    req_body =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> Stripe.URI.encode_query()

    perform_request(req_url, method, req_body, headers, opts)
  end

  @doc """
  A low level utility function to make a direct request to the files Stripe API
  """
  @spec request_file_upload(body, method, String.t(), headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def request_file_upload(body, :post, endpoint, headers, opts) do
    base_url = get_upload_url()
    req_url = base_url <> endpoint

    parts =
      body
      |> Enum.map(fn {key, value} ->
        {Stripe.Util.multipart_key(key), value}
      end)

    perform_request(req_url, :post, {:multipart, parts}, headers, opts)
  end

  def request_file_upload(body, method, endpoint, headers, opts) do
    base_url = get_upload_url()
    req_url = base_url <> endpoint

    req_body =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> Stripe.URI.encode_query()

    perform_request(req_url, method, req_body, headers, opts)
  end

  @doc """
  A low level utility function to make an OAuth request to the Stripe API
  """
  @spec oauth_request(method, String.t(), map, String.t() | nil) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def oauth_request(method, endpoint, body, api_key \\ nil, opts \\ []) do
    base_url = "https://connect.stripe.com/oauth/"
    req_url = base_url <> endpoint
    req_body = Stripe.URI.encode_query(body)
    {api_version, _opts} = Keyword.pop(opts, :api_version)

    req_headers =
      %{}
      |> add_default_headers(req_body)
      |> maybe_add_auth_header_oauth(endpoint, api_key)
      |> add_api_version(api_version)
      |> add_idempotency_headers(method)
      |> Map.to_list()

    do_perform_request(method, req_url, req_headers, req_body, build_req_options([]))
  end

  @spec perform_request(String.t(), method, body, headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  defp perform_request(req_url, method, body, headers, opts) do
    {connect_account_id, opts} = Keyword.pop(opts, :connect_account)
    {api_version, opts} = Keyword.pop(opts, :api_version)
    {api_key, opts} = Keyword.pop(opts, :api_key)

    req_headers =
      headers
      |> add_default_headers(body)
      |> add_auth_header(api_key)
      |> add_connect_header(connect_account_id)
      |> add_api_version(api_version)
      |> add_idempotency_headers(method)
      |> Map.to_list()

    do_perform_request(method, req_url, req_headers, body, build_req_options(opts))
  end

  @spec do_perform_request(method, String.t(), [headers], body, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  defp do_perform_request(method, url, headers, body, opts) do
    do_perform_request_and_retry(method, url, headers, body, opts, {:attempts, 0})
  end

  @spec do_perform_request_and_retry(
          method,
          String.t(),
          [headers],
          body,
          list,
          {:attempts, non_neg_integer} | {:response, http_success | http_failure}
        ) :: {:ok, map} | {:error, Stripe.Error.t()}
  defp do_perform_request_and_retry(_method, _url, _headers, _body, _opts, {:response, response}) do
    handle_response(response)
  end

  defp do_perform_request_and_retry(method, url, headers, body, opts, {:attempts, attempts}) do
    response = perform_req_request(method, url, headers, body, opts)

    do_perform_request_and_retry(
      method,
      url,
      headers,
      body,
      opts,
      add_attempts(response, attempts, retry_config())
    )
  end

  # Performs a single request with Req, normalising the result into the
  # library's internal response shape. Keeping that shape means `should_retry?/3`
  # and `handle_response/1` stay independent of the HTTP client.
  @spec perform_req_request(method, String.t(), [headers], body, Keyword.t()) ::
          http_success | http_failure
  defp perform_req_request(method, url, headers, body, opts) do
    req_options =
      opts
      |> Keyword.merge(method: method, url: url, headers: headers)
      |> put_request_body(body)

    case Req.request(req_options) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, exception} ->
        {:error, transport_reason(exception)}
    end
  end

  @spec put_request_body(Keyword.t(), body) :: Keyword.t()
  defp put_request_body(opts, {:multipart, parts}) do
    Keyword.put(opts, :form_multipart, Enum.map(parts, &multipart_part/1))
  end

  defp put_request_body(opts, body), do: Keyword.put(opts, :body, body)

  # `Stripe.Util.multipart_key/1` tags the file part with the `:file` atom. Its
  # value is a path, optionally `@`-prefixed for parity with curl.
  #
  # Req names multipart parts with atoms. Keys reaching this point are Stripe
  # field names supplied by the application, so the set is bounded.
  @spec multipart_part({atom | String.t(), any}) :: {atom, any}
  defp multipart_part({:file, path}) when is_binary(path) do
    path = String.trim_leading(path, "@")
    {:file, {File.read!(path), filename: Path.basename(path)}}
  end

  defp multipart_part({key, value}) when is_atom(key), do: {key, value}
  defp multipart_part({key, value}) when is_binary(key), do: {String.to_atom(key), value}

  # Req reports transport failures as exception structs (`Req.TransportError`,
  # `Mint.TransportError`, ...). Unwrapping to the bare reason keeps the retry
  # policy in `retry_response?/1` expressed in terms of plain atoms.
  @spec transport_reason(Exception.t()) :: any
  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(exception), do: exception

  @spec add_attempts(http_success | http_failure, non_neg_integer, Keyword.t()) ::
          {:attempts, non_neg_integer} | {:response, http_success | http_failure}
  defp add_attempts(response, attempts, retry_config) do
    if should_retry?(response, attempts, retry_config) do
      response
      |> retry_delay(attempts, retry_config)
      |> :timer.sleep()

      {:attempts, attempts + 1}
    else
      {:response, response}
    end
  end

  # Stripe does not send `Retry-After`; its documented guidance for 429 is an
  # exponential backoff with jitter, which `backoff/2` implements. The header is
  # still honoured when present, since intermediaries can produce a 503 that
  # carries one, and it is capped so a hostile or mistaken value cannot block
  # the caller indefinitely.
  @spec retry_delay(http_success | http_failure, non_neg_integer, Keyword.t()) :: non_neg_integer
  defp retry_delay({:ok, _status, headers, _body}, attempts, retry_config) do
    case fetch_retry_after(headers) do
      nil -> backoff(attempts, retry_config)
      delay -> min(delay, max_retry_after(retry_config))
    end
  end

  defp retry_delay(_response, attempts, retry_config), do: backoff(attempts, retry_config)

  @spec max_retry_after(Keyword.t()) :: non_neg_integer
  defp max_retry_after(config) do
    Keyword.get(config, :max_retry_after) || @default_max_retry_after
  end

  # `Retry-After` may be a number of seconds or an HTTP date. Only the former is
  # recognised; the date form falls back to the exponential backoff rather than
  # pulling in a date parser for a header Stripe does not send.
  @spec fetch_retry_after(map | any) :: non_neg_integer | nil
  defp fetch_retry_after(headers) when is_map(headers) do
    with [value | _] <- Map.get(headers, "retry-after", []),
         {seconds, ""} when seconds >= 0 <- Integer.parse(value) do
      :timer.seconds(seconds)
    else
      _ -> nil
    end
  end

  defp fetch_retry_after(_headers), do: nil

  @doc """
  Returns backoff in milliseconds.
  """
  @spec backoff(attempts :: non_neg_integer, config :: Keyword.t()) :: non_neg_integer
  def backoff(attempts, config) do
    base_backoff = Keyword.get(config, :base_backoff) || @default_base_backoff
    max_backoff = Keyword.get(config, :max_backoff) || @default_max_backoff

    (base_backoff * :math.pow(2, attempts))
    |> min(max_backoff)
    |> backoff_jitter()
    |> max(base_backoff)
    |> trunc()
  end

  @spec backoff_jitter(float) :: float
  defp backoff_jitter(n) do
    # Apply some jitter by randomizing the value in the range of (n / 2) to n
    n * (0.5 * (1 + :rand.uniform()))
  end

  @spec retry_response?(http_success | http_failure) :: boolean
  defp retry_response?({:ok, status, headers, _body}) do
    # Stripe states whether a request is worth retrying in `Stripe-Should-Retry`.
    # It is authoritative in both directions, so it overrides the status based
    # policy below.
    case fetch_should_retry(headers) do
      nil -> retry_status?(status)
      should_retry? -> should_retry?
    end
  end

  # Destination refused the connection, the connection was reset, or a
  # variety of other connection failures. This could occur from a single
  # saturated server, so retry in case it's intermittent.
  defp retry_response?({:error, :econnrefused}), do: true
  # A hackney-era atom for a pooled keep-alive connection that the peer closed
  # after the pool handed it out but before the request was written. Mint
  # reports that case as `:closed` below, so this is unreachable now; it is kept
  # because the policy costs nothing as a superset and the atom is unambiguous.
  defp retry_response?({:error, :invalid_state}), do: true
  # The same stale connection, reported by Mint as `:closed`. Either the pool
  # handed out a socket the peer had already closed, or the request went out and
  # the socket died before the response came back. Whether Stripe processed it is
  # unknowable from here, so this relies on the idempotency key, which is built
  # once per request and reused across attempts. `:conn_max_idle_time` in
  # `finch_pool_options/0` is what keeps this rare.
  defp retry_response?({:error, :closed}), do: true
  # Retry on timeout-related problems (either on open or read).
  defp retry_response?({:error, :connect_timeout}), do: true
  defp retry_response?({:error, :timeout}), do: true
  defp retry_response?(_response), do: false

  @spec retry_status?(integer) :: boolean
  # 409 conflict
  defp retry_status?(409), do: true
  # 429 rate limited
  defp retry_status?(429), do: true
  # Stripe treats 500s as indeterminate - the request may or may not have taken
  # effect. Every non-GET/HEAD request carries an idempotency key, and Stripe
  # guarantees the idempotency of GET and DELETE, so retrying cannot duplicate
  # the operation.
  defp retry_status?(status) when status in [500, 502, 503, 504], do: true
  defp retry_status?(_status), do: false

  # Returns `true`/`false` when Stripe expressed an opinion, `nil` otherwise.
  # Headers are only a map when they came from Req; `should_retry?/3` is public
  # and documented as accepting a plain response tuple, so anything else is
  # treated as "no opinion".
  @spec fetch_should_retry(map | any) :: boolean | nil
  defp fetch_should_retry(headers) when is_map(headers) do
    case Map.get(headers, "stripe-should-retry") do
      ["true" | _] -> true
      ["false" | _] -> false
      _ -> nil
    end
  end

  defp fetch_should_retry(_headers), do: nil

  @spec handle_response(http_success | http_failure) :: {:ok, map} | {:error, Stripe.Error.t()}
  defp handle_response({:ok, status, _headers, body}) when status >= 200 and status <= 299 do
    {:ok, json_library().decode!(body)}
  end

  defp handle_response({:ok, status, headers, body}) when status >= 300 and status <= 599 do
    request_id = fetch_request_id(headers)

    error =
      case json_library().decode(body) do
        {:ok, %{"error_description" => _} = api_error} ->
          Error.from_stripe_error(status, api_error, request_id)

        {:ok, %{"error" => api_error}} ->
          Error.from_stripe_error(status, api_error, request_id)

        {:error, _} ->
          # e.g. if the body is empty
          Error.from_stripe_error(status, nil, request_id)
      end

    {:error, error}
  end

  defp handle_response({:error, reason}) do
    error = Error.from_http_error(reason)
    {:error, error}
  end

  # Req normalises response headers to a map of downcased name => list of values.
  @spec fetch_request_id(map) :: String.t() | nil
  defp fetch_request_id(headers) when is_map(headers) do
    case Map.get(headers, "request-id") do
      [request_id | _] -> request_id
      request_id when is_binary(request_id) -> request_id
      _ -> nil
    end
  end

  defp fetch_request_id(_headers), do: nil

  defp prepend_url("", url), do: url
  defp prepend_url(query, url), do: "#{url}?#{query}"

  defp add_object_expansion(query, expansion) when is_map(query) and is_list(expansion) do
    query |> Map.put(:expand, expansion)
  end

  defp add_object_expansion(url, expansion) when is_list(expansion) do
    expansion
    |> Enum.map(&"expand[]=#{&1}")
    |> Enum.join("&")
    |> prepend_url(url)
  end

  defp add_object_expansion(url, _), do: url

  defp add_idempotency_header(nil, headers, _), do: headers

  defp add_idempotency_header(idempotency_key, headers, :post) do
    Map.put(headers, "Idempotency-Key", idempotency_key)
  end

  defp add_idempotency_header(_, headers, _), do: headers
end
