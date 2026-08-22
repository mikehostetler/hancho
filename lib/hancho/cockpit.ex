defmodule Hancho.Cockpit do
  @moduledoc "A loopback-only cockpit for workflow state and human attention."

  alias Hancho.Workflow.Store

  @spec state(Hancho.Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def state(project, options \\ []) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path),
         {:ok, runs} <- store_api.list_runs(store),
         {:ok, queues} <- store_api.list_queues(store),
         {:ok, handoffs} <- store_api.list_handoffs(store),
         {:ok, attention} <- store_api.list_attention(store) do
      {:ok, %{runs: runs, queues: queues, handoffs: handoffs, attention: attention}}
    end
  end

  @spec serve(Hancho.Project.t(), non_neg_integer(), keyword()) :: no_return()
  def serve(project, port \\ 0, options \\ []) do
    {:ok, socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, actual_port}} = :inet.sockname(socket)
    IO.puts("Hancho cockpit: http://127.0.0.1:#{actual_port}")
    accept(socket, project, options)
  end

  @spec page() :: String.t()
  def page do
    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>Hancho Cockpit</title><style>
    :root{color-scheme:dark}body{font:14px system-ui;margin:0;background:#101311;color:#eef3ee}header{padding:18px 24px;background:#182019;border-bottom:1px solid #334438}main{display:grid;grid-template-columns:1fr 1fr;gap:16px;padding:18px}.panel{background:#182019;border:1px solid #334438;border-radius:10px;padding:16px}.wide{grid-column:1/-1}h1,h2{margin:0 0 12px}.item{border-top:1px solid #334438;padding:10px 0}.pending{color:#ffd166}.ok{color:#76d275}button{margin:5px 5px 0 0;padding:7px 11px}textarea{width:95%;min-height:54px;background:#0e110f;color:#fff}code{color:#a9d6b2}@media(max-width:800px){main{grid-template-columns:1fr}.wide{grid-column:auto}}</style></head>
    <body><header><h1>Hancho Cockpit</h1><span id="live">connecting</span></header><main>
    <section class="panel wide"><h2>Attention</h2><div id="attention"></div></section>
    <section class="panel"><h2>Runs</h2><div id="runs"></div></section>
    <section class="panel"><h2>Queues</h2><div id="queues"></div></section>
    <section class="panel wide"><h2>Role handoffs</h2><div id="handoffs"></div></section></main>
    <script>
    const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const rows=(xs,f)=>xs.length?xs.map(f).join(''):'<div class="item">None</div>';
    async function act(id,action){let response=null;if(action==='answer')response=document.getElementById('r-'+CSS.escape(id)).value;await fetch('/api/attention/'+encodeURIComponent(id)+'/'+action,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({response})});load()}
    async function load(){try{const d=await (await fetch('/api/state')).json();document.getElementById('live').textContent='live · '+new Date().toLocaleTimeString();
    attention.innerHTML=rows(d.attention,a=>`<div class="item"><b class="${a.status==='pending'?'pending':'ok'}">${esc(a.kind)} · ${esc(a.status)}</b><br>${esc(a.title)}<br><small>${esc(a.body)}</small>${a.status==='pending'?`<br><button onclick="act('${esc(a.id)}','approve')">Approve</button><button onclick="act('${esc(a.id)}','reject')">Reject</button><textarea id="r-${esc(a.id)}" placeholder="Answer"></textarea><button onclick="act('${esc(a.id)}','answer')">Answer</button>`:''}</div>`);
    runs.innerHTML=rows(d.runs,r=>`<div class="item"><code>${esc(r.id)}</code> · ${esc(r.workflow_name)} · <b>${esc(r.status)}</b><br>${esc(r.current_step||'complete')}</div>`);
    queues.innerHTML=rows(d.queues,q=>`<div class="item"><code>${esc(q.id)}</code> · ${esc(q.workflow_name)} · <b>${esc(q.status)}</b></div>`);
    handoffs.innerHTML=rows(d.handoffs,h=>`<div class="item"><code>${esc(h.run_id)}</code> · ${esc(h.from_role)} → ${esc(h.to_role)} · ${esc(h.status)}<br>${esc(h.from_step)} → ${esc(h.to_step)}</div>`)}catch(e){live.textContent='disconnected'}}load();setInterval(load,2000);
    </script></body></html>
    """
  end

  defp accept(listener, project, options) do
    {:ok, socket} = :gen_tcp.accept(listener)
    handle(socket, project, options)
    accept(listener, project, options)
  end

  defp handle(socket, project, options) do
    response =
      with {:ok, request} <- receive_request(socket) do
        route(request, project, options)
      else
        _error -> {400, "text/plain", "Bad request"}
      end

    send_response(socket, response)
    :gen_tcp.close(socket)
  end

  defp receive_request(socket) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000),
         [head, body] <- String.split(data, "\r\n\r\n", parts: 2),
         [request_line | _headers] <- String.split(head, "\r\n"),
         [method, path, _version] <- String.split(request_line, " ", parts: 3) do
      {:ok, %{method: method, path: path, body: body}}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp route(%{method: "GET", path: "/"}, _project, _options), do: {200, "text/html", page()}

  defp route(%{method: "GET", path: "/api/state"}, project, options) do
    case state(project, options) do
      {:ok, value} -> {200, "application/json", Jason.encode!(value)}
      {:error, reason} -> {500, "application/json", Jason.encode!(%{error: inspect(reason)})}
    end
  end

  defp route(%{method: "POST", path: path, body: body}, project, options) do
    case Regex.run(~r{^/api/attention/([^/]+)/(approve|reject|answer)$}, path) do
      [_, encoded_id, action] -> resolve(project, URI.decode(encoded_id), action, body, options)
      _other -> {404, "text/plain", "Not found"}
    end
  end

  defp route(_request, _project, _options), do: {404, "text/plain", "Not found"}

  defp resolve(project, id, action, body, options) do
    store_api = Keyword.get(options, :store_api, Store)
    status = %{"approve" => "approved", "reject" => "rejected", "answer" => "answered"}[action]

    response =
      case Jason.decode(body) do
        {:ok, %{"response" => value}} -> value
        _ -> nil
      end

    with {:ok, store} <- store_api.open(project.bedrock_path),
         {:ok, record} <- store_api.resolve_attention(store, id, status, response) do
      {200, "application/json", Jason.encode!(record)}
    else
      {:error, reason} -> {409, "application/json", Jason.encode!(%{error: inspect(reason)})}
    end
  end

  defp send_response(socket, {status, content_type, body}) do
    reason =
      %{
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error"
      }[status]

    headers =
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: #{content_type}; charset=utf-8\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"

    :gen_tcp.send(socket, headers <> body)
  end
end
