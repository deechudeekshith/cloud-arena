/* Cloud Arena room monitor — room/session centric. No frameworks, no CDN.
   Every value comes from the API/WebSocket. N/A when not measured. */
const $ = s => document.querySelector(s);
const NA = (v,d=1)=> (v===null||v===undefined||v<0) ? "N/A" : Number(v).toFixed(d);
const KB = v => v==null||v<0 ? "N/A" : v>=1048576 ? (v/1048576).toFixed(2)+" MB"
           : v>=1024 ? (v/1024).toFixed(1)+" KB" : Math.round(v)+" B";
const KBs= v => v==null||v<0 ? "N/A" : v>=1048576 ? (v/1048576).toFixed(2)+" MB/s"
           : v>=1024 ? (v/1024).toFixed(0)+" KB/s" : Math.round(v)+" B/s";
const esc= s => String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const hhmmss = s => { if(!s) return "—"; const d=new Date(s);
  return String(d.getHours()).padStart(2,"0")+":"+String(d.getMinutes()).padStart(2,"0")
        +":"+String(d.getSeconds()).padStart(2,"0"); };
const dur = s => { if(!s||s<0) return "—"; const m=Math.floor(s/60), x=Math.floor(s%60);
  return String(m).padStart(2,"0")+":"+String(x).padStart(2,"0"); };
// Real session length from stored timestamps. A session with no ended_at is
// still running, so it is measured against now and marked as live.
const durOf = s => { if(!s||!s.created_at) return "—";
  const a=new Date(s.created_at).getTime(); if(isNaN(a)) return "—";
  const b=s.ended_at?new Date(s.ended_at).getTime():Date.now(); if(isNaN(b)) return "—";
  return dur(Math.max(0,(b-a)/1000)) + (s.ended_at?"":" live"); };
const api = {
  async get(p){ const r=await fetch(p); const t=await r.text();
    if(!r.ok) throw new Error(t.slice(0,160)); return JSON.parse(t); },
  async post(p,b){ const r=await fetch(p,{method:"POST",
      headers:{"Content-Type":"application/json"},body:JSON.stringify(b||{})});
    const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||r.statusText); return j; }
};
window.addEventListener("error",e=>{ const el=$("#fatal"); el.classList.remove("hidden");
  el.textContent="JS ERROR: "+e.message+" @ "+e.filename+":"+e.lineno; });

const S = { rooms:[], room:null, detail:null, win:300, samples:[], view:"rooms",
            sessions:[], replay:{rows:[],pos:0,playing:false}, demo:false };

/* ── nav ─────────────────────────────────────────────────── */
document.querySelectorAll("#tabs button").forEach(b=>b.onclick=()=>{
  document.querySelectorAll("#tabs button").forEach(x=>x.classList.remove("sel"));
  b.classList.add("sel");
  document.querySelectorAll(".view").forEach(v=>v.classList.remove("sel"));
  $("#view-"+b.dataset.v).classList.add("sel");
  S.view = b.dataset.v;
  if(S.view==="history") loadHistory();
  if(S.view==="compare") loadCmpSel();
  if(S.view==="export") loadExpSel();
  if(S.view==="settings") loadSettings();
});
$("#btn-refresh").onclick = ()=>{ loadRooms(); loadDetail(); };

/* ── websocket ──────────────────────────────────────────── */
let ws=null, retry=1000;
function connect(){
  ws = new WebSocket((location.protocol==="https:"?"wss://":"ws://")+location.host+"/ws");
  ws.onopen = ()=>{ retry=1000; setServer(true); };
  ws.onmessage = ev => { try{ const m=JSON.parse(ev.data);
      if(m.type==="CMD_ACK"){ loadCmdLog(); return; }
      setGame(m.connection||"DISCONNECTED");
      if(m.connection==="CONNECTED"){ loadRooms(); if(S.room) loadDetail(); }
    }catch(e){} };
  ws.onclose = ()=>{ setServer(false); setGame("DISCONNECTED");
    setTimeout(connect, retry); retry=Math.min(8000, retry*2); };
  ws.onerror = ()=>{ try{ws.close();}catch(e){} };
}
function setServer(ok){ const e=$("#tb-server"); e.textContent=ok?"ONLINE":"OFFLINE";
  e.className="dot "+(ok?"on":"off"); }
function setGame(c){ const e=$("#tb-game"); e.textContent=c;
  e.className="dot "+(c==="CONNECTED"?"on":c==="RECONNECTING"?"mid":"off"); }

/* ── rooms ───────────────────────────────────────────────── */
async function loadRooms(){
  let d; try{ d = await api.get("/api/rooms"); }catch(e){ return; }
  S.rooms = d.rooms || [];
  const conn = S.rooms.reduce((a,r)=>a+(r.devices_connected||0),0);
  $("#tb-rooms").textContent = S.rooms.length;
  $("#tb-devices").textContent = conn;
  $("#rooms-count").textContent = S.rooms.length ? `(${S.rooms.length})` : "";
  $("#rooms-list").innerHTML = S.rooms.length ? S.rooms.map(r=>`
    <div class="roomcard ${S.room===r.code?"sel":""}" data-code="${r.code}">
      <div><span class="code">${r.code}</span>
        <span class="st ${r.state}">${r.state}</span></div>
      <div class="rrow"><span>Players</span><b>${r.players} / ${r.max_players}</b></div>
      <div class="rrow"><span>Devices</span><b>${r.devices} (${r.devices_connected} on)</b></div>
      <div class="rrow"><span>Match</span><b>${r.match_status}</b></div>
      <div class="rrow"><span>Session</span><b>${dur(r.session_elapsed)}</b></div>
      <div class="rrow"><span>Optimization</span><b>${esc(r.optimization)}</b></div>
      <div class="rrow"><span>Bandwidth</span><b>${r.bandwidth_kbps>0?r.bandwidth_kbps+" KB/s":"Unlimited"}</b></div>
      <button class="openbtn">OPEN ROOM</button>
    </div>`).join("")
    : `<div class="dim" style="padding:14px">No rooms yet.<br>Start Cloud Arena → Create Room.</div>`;
  document.querySelectorAll(".roomcard").forEach(el=>{
    el.onclick = ()=>{ S.room = el.dataset.code; S.samples=[]; loadRooms(); loadDetail(); };
  });
}

/* ── room detail ────────────────────────────────────────── */
async function loadDetail(){
  if(!S.room) return;
  let d; try{ d = await api.get("/api/rooms/"+S.room); }catch(e){ return; }
  S.detail = d;
  const r = d.room, s = d.session;
  $("#room-empty").classList.add("hidden");
  $("#room-view").classList.remove("hidden");
  $("#room-title").textContent = "ROOM " + r.code + (s? "   SESSION #"+s.session_no : "");
  const st=$("#room-state"); st.textContent = r.state; st.className="pill "+
    (r.state==="PLAYING"||r.state==="ACTIVE"?"on":"");
  const rec=$("#room-rec");
  if(s && s.status==="OPEN"){ rec.classList.remove("hidden"); }
  else rec.classList.add("hidden");

  const kv = (k,v)=>`<div><span>${k}</span><span>${v}</span></div>`;
  const mm = (d.devices||[]).reduce((a,x)=>a+(x.left_at?0:1),0);
  $("#room-summary").innerHTML =
     kv("Room Number", r.code) + kv("Room Status", r.state)
   + kv("Host", r.host_name||r.host_device||"—")
   + kv("Players", `${mm} / ${d.room.max_players||8}`)
   + kv("Devices", `${(d.devices||[]).length}`)
   + kv("Match Status", r.match_started_at ? (r.match_ended_at?"ENDED":"RUNNING") : "NOT STARTED")
   + kv("Session Duration", dur(d.session_elapsed))
   + kv("Match Duration", dur(d.match_elapsed))
   + kv("Session Started", hhmmss(s&&s.created_at))
   + kv("Optimization", s?(s.optimization_mode||"PENDING"):"—")
   + kv("Bandwidth Limit", s&&s.network_config ? (JSON.parse(s.network_config||"{}").budget_kbps||"Unlimited") : "Unlimited");

  renderCards();
  renderDevices();
  renderEvents(d.events||[]);
  renderCfgHistory(d.config_history||[]);
  loadSamples();
  buildControls();
}

function renderCards(){
  const rows = S.samples||[];
  const last = rows[rows.length-1]||{};
  const per = {};
  for(const r of rows){ (per[r.device_id]=per[r.device_id]||[]).push(r); }
  const devs = Object.keys(per);
  const vals = k => { const v=[]; for(const d of devs) for(const r of per[d])
      if(r[k]!=null&&r[k]>=0) v.push(r[k]); return v; };
  const mean = a => a.length? a.reduce((x,y)=>x+y,0)/a.length : -1;
  const avg = k => mean(vals(k));
  const up=avg("up_bps"), dn=avg("dn_bps"), rtt=avg("rtt"), fps=avg("fps"),
        loss=avg("loss");
  // "PC CPU/RAM" must mean the HOST only. Averaging the guests in would
  // mislabel a phone's CPU as the PC's, so the host device is picked by role
  // and the card falls back to N/A when the host never reported.
  const hostId = (S.detail?.devices||[]).find(d=>d.role==="host")?.device_id;
  const hostRows = hostId ? (per[hostId]||[]) : [];
  const hostAvg = k => { const v=[]; for(const r of hostRows)
      if(r[k]!=null&&r[k]>=0) v.push(r[k]); return v.length
        ? v.reduce((a,b)=>a+b,0)/v.length : -1; };
  const cpu=hostAvg("cpu"), ram=hostAvg("ram");
  const hostUp=hostAvg("up_bps"), hostDn=hostAvg("dn_bps");
  const card=(h,v,u,cls)=>`<div class="card"><h4>${h}</h4>
    <div class="v ${cls||""}">${v}</div><div class="u">${u}</div></div>`;
  const hostNote = hostId ? "host only" : "host not reporting";
  $("#room-cards").innerHTML =
      card("FPS", NA(fps,0), "avg across devices")
    + card("RTT", rtt>=0?NA(rtt,0):"N/A", "ms · avg")
    + card("PING", NA(avg("ping"),0), "ms · avg")
    + card("PC CPU", cpu>=0?NA(cpu):"N/A", "% · " + hostNote)
    + card("PC RAM", ram>=0?(ram/1024).toFixed(2):"N/A", "GB · " + hostNote)
    + card("PC UPLOAD", KBs(hostUp), "KB/s · host only")
    + card("PC DOWNLOAD", KBs(hostDn), "KB/s · host only")
    + card("PACKET LOSS", loss>=0?(loss*100).toFixed(2)+"%":"N/A", "avg")
    + card("TRANSFERRED", KB(last.comp), "")
    + card("ORIGINAL", KB(last.orig), "")
    + card("DEVICES", String(devs.length), "reporting")
    + card("SAMPLES", String(rows.length), "1 Hz");
}

function renderDevices(){
  const devs = S.detail?.devices || [];
  const metrics = S.detail?.device_metrics || {};
  const rows = devs.map(d=>{
    const m = metrics[d.device_id]||{};
    const conn = !d.left_at;
    return `<tr class="clickable" data-dev="${d.device_id}">
      <td>${esc(d.name||d.device_id)}</td>
      <td>${esc(d.role||"client")}</td>
      <td>${esc(d.platform||"N/A")}</td>
      <td class="${conn?"":"na"}">${conn?"● CONNECTED":"○ DISCONNECTED"}</td>
      <td class="num">${NA(m.fps,0)}</td>
      <td class="num">${m.rtt>=0?NA(m.rtt,0)+" ms":"N/A"}</td>
      <td>${hhmmss(d.joined_at)}</td>
      <td class="na">${d.left_at?hhmmss(d.left_at):"—"}</td></tr>`;
  });
  $("#dev-table").innerHTML = `<tr><th>Device</th><th>Role</th><th>Platform</th>
    <th>Status</th><th>FPS</th><th>Ping</th><th>Joined</th><th>Left</th></tr>` + rows.join("");
  document.querySelectorAll("#dev-table tr.clickable").forEach(tr=>tr.onclick=()=>{
    const id=tr.dataset.dev, d=devs.find(x=>x.device_id===id), m=metrics[id]||{};
    const last = (S.samples||[]).filter(r=>r.device_id===id).pop()||{};
    const box=$("#dev-detail"); box.classList.remove("hidden");
    const kv=(k,v)=>`<div><span>${k}</span><span>${v}</span></div>`;
    box.innerHTML = `<b>${esc(d?.name||id)}</b> detail —
      ` + kv("Device", esc(d?.name||"N/A")) + kv("Platform", esc(d?.platform||"N/A"))
      + kv("Room", S.room) + kv("Joined", hhmmss(d?.joined_at))
      + kv("Status", d?.left_at?"DISCONNECTED":"CONNECTED")
      + kv("Role", esc(d?.role||"N/A"))
      + kv("FPS", NA(m.fps,0)) + kv("Ping", m.ping>=0?NA(m.ping,0)+" ms":"N/A")
      + kv("RTT", m.rtt>=0?NA(m.rtt,0)+" ms":"N/A")
      + kv("CPU", m.cpu>=0?NA(m.cpu)+" %":"N/A")
      + kv("RAM", m.ram>=0?NA(m.ram,0)+" MB":"N/A")
      + kv("Upload", KBs(last.up_bps)) + kv("Download", KBs(last.dn_bps))
      + kv("Packet loss", m.loss>=0?(m.loss*100).toFixed(2)+" %":"N/A")
      + kv("Battery / Temp", "N/A (not provided by this client)");
  });
}

function renderEvents(evs){
  $("#room-events").innerHTML = evs.length ? evs.map(e=>
    `<div class="ev"><span class="t">${hhmmss(e.timestamp)}</span>
     <span class="k">${esc(e.type)}</span><span>${esc(e.detail||"")}</span></div>`).join("")
    : `<div class="dim">No events recorded yet.</div>`;
}
function renderCfgHistory(rows){
  $("#cfg-history").innerHTML = rows.length ? rows.map(r=>
    `<div class="ev"><span class="t">${hhmmss(r.timestamp)}</span>
     <span class="k">${esc(r.kind)} · ${esc(r.field)}</span>
     <span>${esc(r.old_value)} → ${esc(r.new_value)}</span></div>`).join("")
    : `<div class="dim">No configuration changes recorded.</div>`;
}

/* ── samples + charts ────────────────────────────────────── */
async function loadSamples(){
  if(!S.room) return;
  let d; try{ d = await api.get(`/api/rooms/${S.room}/samples`); }catch(e){ return; }
  S.samples = d.samples||[];
  renderCards(); drawCharts();
}
document.querySelectorAll("#winbtns button").forEach(b=>b.onclick=()=>{
  document.querySelectorAll("#winbtns button").forEach(x=>x.classList.remove("sel"));
  b.classList.add("sel"); S.win = parseInt(b.dataset.w,10); drawCharts();
});

function setup(cv){ const dpr=window.devicePixelRatio||1, r=cv.getBoundingClientRect();
  cv.width=Math.max(60,r.width*dpr); cv.height=r.height*dpr;
  const x=cv.getContext("2d"); x.setTransform(dpr,0,0,dpr,0,0); return [x,r.width,r.height]; }
function win(pts,w){ if(!pts.length) return pts;
  if(!w) return pts; const t1=pts[pts.length-1][0], out=[];
  for(let i=pts.length-1;i>=0;i--){ if(t1-pts[i][0]>w) break; out.push(pts[i]); } return out.reverse(); }
function dec(pts,n=240){ if(pts.length<=n) return pts;
  const s=Math.ceil(pts.length/n), o=[]; for(let i=0;i<pts.length;i+=s) o.push(pts[i]); return o; }
function chart(id, series, unit){
  const cv=$(id); if(!cv) return;
  const [x,W,H]=setup(cv); x.clearRect(0,0,W,H);
  const pad={l:46,r:6,t:6,b:14}, w=W-pad.l-pad.r, h=H-pad.t-pad.b;
  let mn=Infinity,mx=-Infinity,t0=Infinity,t1=-Infinity;
  for(const s of series) for(const p of s.pts){ if(p[1]<mn)mn=p[1]; if(p[1]>mx)mx=p[1];
    t0=Math.min(t0,p[0]); t1=Math.max(t1,p[0]); }
  if(!isFinite(mn)){ x.fillStyle="#8698b5"; x.font="11px monospace";
    x.fillText("no data",pad.l,H/2); return; }
  if(t1-t0<1e-9) t1=t0+1; if(mx-mn<1e-9) mx=mn+1;
  const X=t=>pad.l+w*(t-t0)/(t1-t0), Y=v=>pad.t+h*(1-(v-mn)/(mx-mn));
  x.strokeStyle="#1f2c42"; x.fillStyle="#8698b5"; x.font="9px monospace"; x.lineWidth=1;
  for(let i=0;i<=3;i++){ const v=mn+(mx-mn)*i/3, y=Y(v);
    x.beginPath(); x.moveTo(pad.l,y); x.lineTo(W-pad.r,y); x.stroke();
    x.fillText(v>=1000?(v/1000).toFixed(1)+"k":v.toFixed(1),2,y+3); }
  series.forEach((s,i)=>{ if(s.pts.length<2) return;
    x.strokeStyle=s.color||["#4aa3ff","#35d97f","#ffb020"][i%3]; x.lineWidth=1.5;
    x.beginPath(); s.pts.forEach((p,j)=>{ const px=X(p[0]),py=Y(p[1]); j?x.lineTo(px,py):x.moveTo(px,py); });
    x.stroke(); });
  series.forEach((s,i)=>{ x.fillStyle=s.color||["#4aa3ff","#35d97f","#ffb020"][i%3];
    x.fillText(s.label, pad.l+i*110, H-3); });
}
function drawCharts(){
  const per={}; for(const r of S.samples){ (per[r.device_id]=per[r.device_id]||[]).push(r); }
  const ser=(k,label,color,scale=1)=> Object.keys(per).map((d,i)=>
    ({label: label+(Object.keys(per).length>1?` ${d.slice(-4)}`:""),
      color:["#4aa3ff","#35d97f","#ffb020","#c07bff"][i%4],
      pts: dec(win(per[d].map(r=>[r.t,(r[k]==null||r[k]<0)?null:r[k]*scale]).filter(p=>p[1]!=null), S.win))}));
  chart("#g-fps", ser("fps","FPS"), "fps");
  chart("#g-rtt", [...ser("rtt","RTT","#4aa3ff"), ...ser("ping","PING","#ffb020")], "ms");
  chart("#g-bw", ser("up_bps","up B/s","#4aa3ff"), "B/s");
  chart("#g-cpu", ser("cpu","CPU %","#ffb020"), "%");
  chart("#g-data", [...ser("orig","original B","#8698b5"), ...ser("comp","sent B","#35d97f")], "B");
  chart("#g-loss", ser("loss","loss","#ff5d5d",100), "%");
}

/* ── controls ────────────────────────────────────────────── */
const BW=[["Unlimited",0],["10 Mbps",1250],["5 Mbps",625],["2 Mbps",250],["1 Mbps",125],
          ["512 Kbps",64],["256 Kbps",32],["128 Kbps",16],["Custom",-1]];
const TECH=[["Disabled",{}],
  ["Baseline / Normal",{"delta_enabled":false,"dedup_enabled":false,"compression_enabled":false,"priority_enabled":false,"partial_enabled":false}],
  ["Delta Transfer",{"delta_enabled":true,"dedup_enabled":false,"compression_enabled":false}],
  ["Deduplication",{"delta_enabled":false,"dedup_enabled":true,"compression_enabled":false}],
  ["Compression",{"delta_enabled":false,"dedup_enabled":false,"compression_enabled":true}],
  ["Priority Scheduling",{"priority_enabled":true}],
  ["Delta + Compression",{"delta_enabled":true,"dedup_enabled":false,"compression_enabled":true}],
  ["Dedup + Compression",{"delta_enabled":false,"dedup_enabled":true,"compression_enabled":true}],
  ["Full Optimization",{"delta_enabled":true,"dedup_enabled":true,"compression_enabled":true,"priority_enabled":true,"partial_enabled":true}]];
const PRESETS=[["LAN",0,0,0],["Good Wi-Fi",20,5,0.2],["Average Wi-Fi",50,15,1],
               ["Poor Wi-Fi",120,40,3],["Mobile-like",200,80,5]];
let customBw=null;

function buildControls(){
  if($("#ctl").dataset.built) return;
  $("#ctl").dataset.built="1";
  const opt=(a)=>a.map(([t,v])=>`<option value="${v}">${t}</option>`).join("");
  $("#ctl").innerHTML = `
    <div class="row">
      <div><label class="f">Optimization</label>
        <select id="c-opt"><option value="1">ENABLED</option><option value="0">DISABLED</option></select></div>
      <div><label class="f">Technique (implemented only)</label>
        <select id="c-tech">${opt(TECH.map((t,i)=>[t[0],i]))}</select></div>
    </div>
    <div class="row">
      <div><label class="f">Bandwidth limit</label><select id="c-bw">${opt(BW)}</select></div>
      <div><label class="f">Custom KB/s</label><input id="c-bwc" type="number" min="0" max="12500" value="0"></div>
      <div><label class="f">Update rate</label><select id="c-hz">${opt([5,10,15,20,30,60].map(v=>[v+" Hz",v]))}</select></div>
    </div>
    <div class="row">
      <div><label class="f">Latency ms</label><input id="c-lat" type="number" min="0" max="5000" value="0"></div>
      <div><label class="f">Jitter ms</label><input id="c-jit" type="number" min="0" max="5000" value="0"></div>
      <div><label class="f">Packet loss %</label><input id="c-loss" type="number" min="0" max="100" step="0.5" value="0"></div>
      <div><label class="f">Network preset</label><select id="c-pre">${opt(PRESETS.map((p,i)=>[p[0],i]))}</select></div>
    </div>
    <div class="row"><div style="flex:1"><b class="warn">SIMULATED NETWORK CONDITIONS</b>
      <div class="dim" style="font-size:11px">Latency / jitter / loss shape the link in the game. Bandwidth is a hard enforced budget.</div></div></div>`;
  $("#c-bw").onchange = ()=>{ const v=$("#c-bw").value;
    if(v==="-1"){ $("#c-bwc").value = customBw??125; } else customBw=null; };
  $("#c-pre").onchange = ()=>{ const p=PRESETS[+$("#c-pre").value];
    if(p){ $("#c-lat").value=p[1]; $("#c-jit").value=p[2]; $("#c-loss").value=p[3]; } };
  $("#btn-apply").onclick = applyConfig;
  $("#btn-reset").onclick = ()=>{ $("#c-opt").value="1"; $("#c-tech").value=TECH.length-1;
    $("#c-bw").value="0"; $("#c-bwc").value="0"; $("#c-hz").value="20";
    $("#c-lat").value=0; $("#c-jit").value=0; $("#c-loss").value=0; $("#c-pre").value="0";
    $("#ctl-msg").innerHTML='<span class="dim">Reset. Press APPLY to send to the game.</span>'; };
  document.querySelectorAll("[data-g]").forEach(b=>b.onclick=()=>gameCmd(b.dataset.g));
}

async function applyConfig(){
  const msg=$("#ctl-msg"); msg.innerHTML='<span class="dim">Sending…</span>';
  const enabled = $("#c-opt").value==="1";
  const tech = TECH[+$("#c-tech").value][1];
  const settings = enabled ? tech : {delta_enabled:false,dedup_enabled:false,
    compression_enabled:false,priority_enabled:false,partial_enabled:false};
  const bwSel=$("#c-bw").value;
  const bw = bwSel==="-1" ? parseFloat($("#c-bwc").value||"0") : parseFloat(bwSel);
  const hz = parseFloat($("#c-hz").value);
  const lat=parseFloat($("#c-lat").value||"0"), jit=parseFloat($("#c-jit").value||"0"),
        loss=parseFloat($("#c-loss").value||"0");
  try{
    if(bw<0||bw>12500) throw new Error("bandwidth must be 0..12500 KB/s");
    if(hz<5||hz>60) throw new Error("update rate must be 5..60 Hz");
    if(lat<0||lat>5000) throw new Error("latency must be 0..5000 ms");
    if(jit<0||jit>5000) throw new Error("jitter must be 0..5000 ms");
    if(loss<0||loss>100) throw new Error("packet loss must be 0..100 %");
    await api.post("/api/config/opt",{name:"dashboard",settings,apply_to_game:true});
    // one merged set_net: budget/update-rate/link conditioner land as a single
    // atomic change in the session's config history
    await api.post("/api/send-command",{cmd:"set_net",
      params:{budget_kbps:bw,update_hz:hz,latency_ms:lat,jitter_ms:jit,loss_pct:loss}});
    await api.post("/api/config/net",{name:"dashboard",
      settings:{bandwidth_kbps:bw,latency_ms:lat,jitter_ms:jit,loss_pct:loss},
      apply_to_game:false});
    msg.innerHTML='<span class="ok">✓ COMMANDS SENT — awaiting game ACK (see command log)</span>';
    setTimeout(loadCmdLog, 2500);
  }catch(e){ msg.innerHTML='<span class="bad">✕ Failed to apply configuration: '+esc(e.message)+"</span>"; }
}

async function gameCmd(cmd){
  const m=$("#game-msg"); m.innerHTML='<span class="dim">Sending…</span>';
  try{ const r=await api.post("/api/send-command",{cmd,params:{}});
    m.innerHTML=`<span class="ok">✓ COMMAND SENT (id ${r.id}) — see ACK</span>`;
    setTimeout(loadCmdLog,2500);
  }catch(e){ m.innerHTML='<span class="bad">✕ Failed: '+esc(e.message)+"</span>"; }
}

async function loadCmdLog(){
  let d; try{ d = await api.get("/api/commands-log"); }catch(e){ return; }
  $("#cmd-log").innerHTML = `<table><tr><th>id</th><th>cmd</th><th>status</th><th>result</th></tr>`+
    d.commands.slice(0,20).map(c=>`<tr><td class="mono">${c.id}</td><td class="mono">${esc(c.cmd)}</td>
      <td class="${c.status==="APPLIED"?"ok":c.status==="FAILED"?"bad":"warn"}">${esc(c.status)}</td>
      <td class="dim">${esc(c.result||"")}</td></tr>`).join("")+"</table>";
}

/* ── history / replay ────────────────────────────────────── */
async function loadHistory(){
  let d; try{ d = await api.get("/api/sessions"); }catch(e){ return; }
  S.sessions = d.sessions||[];
  $("#hist-table").innerHTML = `<tr><th>Room</th><th>Session</th><th>Devices</th><th>Created</th>
    <th>Duration</th><th>Mode</th><th>Status</th><th></th></tr>` + S.sessions.map(s=>{
      const dev = S.sessions.length; return `<tr class="clickable" data-sid="${s.id}">
      <td class="mono">${esc(s.room_code)}</td><td class="mono">#${s.session_no}</td>
      <td>${s.device_count||"—"}</td><td class="dim">${hhmmss(s.created_at)}</td>
      <td class="num">${durOf(s)}</td>
      <td>${esc(s.optimization_mode||"—")}</td><td>${esc(s.status)}</td>
      <td><button data-x="${s.id}">VIEW</button></td></tr>`;}).join("");
  document.querySelectorAll("#hist-table tr.clickable").forEach(tr=>tr.onclick=()=>loadReplay(tr.dataset.sid));
  document.querySelectorAll("#hist-table button[data-x]").forEach(b=>b.onclick=(e)=>{
    e.stopPropagation(); loadReplay(b.dataset.x); });
}
async function loadReplay(sid){
  let d; try{ d = await api.get("/api/sessions/"+sid); }catch(e){ alert(e.message); return; }
  $("#replay-box").classList.remove("hidden");
  S.replay = {rows:d.samples||[], pos:0, playing:false, report:d.report, events:d.events||[]};
  $("#rp-csv").onclick=()=>location.href=`/api/sessions/export/${sid}?format=csv`;
  $("#rp-json").onclick=()=>location.href=`/api/sessions/export/${sid}?format=json`;
  drawReplay();
}
$("#rp-play").onclick=()=>{ const R=S.replay; if(!R.rows.length) return;
  R.playing=!R.playing; $("#rp-play").textContent=R.playing?"⏸ Pause":"▶ Play";
  clearInterval(R.timer);
  if(R.playing) R.timer=setInterval(()=>{ R.pos+=Math.max(1,Math.floor(R.rows.length/300));
    if(R.pos>=R.rows.length){ R.pos=R.rows.length-1; R.playing=false;
      $("#rp-play").textContent="▶ Play"; clearInterval(R.timer); }
    $("#rp-pos").value=Math.round(1000*R.pos/Math.max(1,R.rows.length-1)); drawReplay(); },80); };
$("#rp-pos").oninput=e=>{ S.replay.pos=Math.round(S.replay.rows.length*e.target.value/1000);
  drawReplay(); };
function drawReplay(){
  const R=S.replay; if(!R.rows.length) return;
  const upto=R.rows.slice(0,R.pos+1);
  const agg=k=>{ const m={}; for(const r of upto){ if(r[k]!=null&&r[k]>=0){ (m[r.t]=m[r.t]||[]).push(r[k]); } }
    return Object.entries(m).map(([t,v])=>[+t, v.reduce((a,b)=>a+b,0)/v.length]); };
  chart("#rp-chart",[{label:"FPS",color:"#4aa3ff",pts:agg("fps")},
                     {label:"RTT ms",color:"#ffb020",pts:agg("rtt")}], "");
  const last=upto[upto.length-1]||{};
  const rp=R.report||{};
  const kv=(k,v)=>`<div><span>${k}</span><span>${v}</span></div>`;
  $("#rp-stats").innerHTML = kv("Cursor", dur(last.t)) + kv("FPS", NA(last.fps,0))
    + kv("CPU", NA(last.cpu)+" %") + kv("RAM", last.ram>=0?NA(last.ram,0)+" MB":"N/A")
    + kv("RTT", last.rtt>=0?NA(last.rtt,0)+" ms":"N/A")
    + kv("Upload", KBs(last.up_bps)) + kv("Download", KBs(last.dn_bps))
    + kv("Data sent", KB(last.bytes_sent)) + kv("Transferred", KB(last.comp))
    + kv("Avg FPS (session)", NA(rp.avg_fps,1)) + kv("Min FPS", NA(rp.min_fps,0))
    + kv("Avg RTT (session)", rp.avg_rtt>=0?NA(rp.avg_rtt,1)+" ms":"N/A")
    + kv("Data reduction", rp.reduction_pct>=0?NA(rp.reduction_pct,1)+" %":"N/A");
  $("#rp-time").textContent = dur(last.t);
}

/* ── compare ─────────────────────────────────────────────── */
async function loadCmpSel(){
  let d; try{ d = await api.get("/api/sessions"); }catch(e){ return; }
  const o=S.sessions.length?S.sessions.map(s=>`<option value="${s.id}">${s.room_code} #${s.session_no} [${esc(s.optimization_mode||"?")}]</option>`).join(""):"";
  $("#cmp-a").innerHTML=o; $("#cmp-b").innerHTML=o;
  if(S.sessions.length>1) $("#cmp-b").value=S.sessions[S.sessions.length-2].id;
}
$("#cmp-go").onclick=async()=>{
  const a=$("#cmp-a").value,b=$("#cmp-b").value;
  if(!a||!b||a===b) { $("#cmp-out").innerHTML='<div class="msg warn">Pick two different sessions.</div>'; return; }
  let d; try{ d=await api.get(`/api/sessions/compare?a=${a}&b=${b}`); }catch(e){
    $("#cmp-out").innerHTML='<div class="msg bad">'+esc(e.message)+"</div>"; return; }
  const rows=[["Avg FPS","avg_fps",v=>NA(v,1)],["Min FPS","min_fps",v=>NA(v,0)],
    ["Avg RTT","avg_rtt",v=>v>=0?NA(v,1)+" ms":"N/A"],["Avg ping","avg_ping",v=>v>=0?NA(v,1)+" ms":"N/A"],
    ["Data transferred","transferred",v=>KB(v)],["Original data","original",v=>KB(v)],
    ["Data reduction","reduction_pct",v=>v>=0?NA(v,1)+" %":"N/A"],
    ["Avg upload","avg_up",v=>KBs(v)],["Avg download","avg_dn",v=>KBs(v)],
    ["Packet loss","avg_loss",v=>v>=0?(v*100).toFixed(2)+" %":"N/A"],
    ["Avg PC CPU","avg_cpu",v=>v>=0?NA(v,1)+" %":"N/A"],
    ["Avg PC RAM","avg_ram",v=>v>=0?(v/1024).toFixed(2)+" GB":"N/A"],
    ["Duration","duration_s",v=>dur(v)]];
  const A=d.a.report,B=d.b.report;
  let h=`<table><tr><th>Metric</th><th>${esc(a)}</th><th>${esc(b)}</th></tr>`;
  for(const [l,k,f] of rows) h+=`<tr><td>${l}</td><td class="num">${f(A[k])}</td><td class="num">${f(B[k])}</td></tr>`;
  h+="</table>";
  h+=`<div class="panel"><h3>EXPERIMENTAL CONDITIONS</h3><table>
    <tr><th></th><th>${esc(a)}</th><th>${esc(b)}</th></tr>
    <tr><td>Room</td><td>${esc(d.conditions[a].room)}</td><td>${esc(d.conditions[b].room)}</td></tr>
    <tr><td>Players</td><td>${d.conditions[a].players}</td><td>${d.conditions[b].players}</td></tr>
    <tr><td>Mode</td><td>${esc(d.conditions[a].mode||"—")}</td><td>${esc(d.conditions[b].mode||"—")}</td></tr>
    <tr><td>Bandwidth limit</td><td>${d.conditions[a].bandwidth?d.conditions[a].bandwidth+" KB/s":"Unlimited"}</td>
        <td>${d.conditions[b].bandwidth?d.conditions[b].bandwidth+" KB/s":"Unlimited"}</td></tr>
    <tr><td>Duration</td><td>${dur(d.conditions[a].duration_s)}</td><td>${dur(d.conditions[b].duration_s)}</td></tr>
    </table><div class="msg ${d.conditions_match?"ok":"warn"}">${
      d.conditions_match?"✓ Same player count and bandwidth — controlled comparison":
      "⚠ Conditions differ — treat differences as indicative."}</div>
    <div class="dim">${esc(d.note)}</div></div>`;
  $("#cmp-out").innerHTML=h;
};

/* ── export / settings ───────────────────────────────────── */
async function loadExpSel(){
  let d; try{ d = await api.get("/api/sessions"); }catch(e){ return; }
  const o=d.sessions.map(s=>`<option value="${s.id}">${s.room_code} #${s.session_no}</option>`).join("");
  $("#exp-sel").innerHTML=o;
  $("#exp-csv").onclick=()=>{const v=$("#exp-sel").value; if(v) location.href=`/api/sessions/export/${v}?format=csv`;};
  $("#exp-json").onclick=()=>{const v=$("#exp-sel").value; if(v) location.href=`/api/sessions/export/${v}?format=json`;};
}
async function loadSettings(){
  let d; try{ d = await api.get("/api/settings"); }catch(e){ return; }
  const kv=(k,v)=>`<div><span>${k}</span><span>${v}</span></div>`;
  $("#set-info").innerHTML = kv("Dashboard URL", `http://127.0.0.1:${d.port}`)
    + kv("Backend", `python3 server.py --port ${d.port}`)
    + kv("Database", esc(d.db)) + kv("Game path", esc(d.game_path))
    + kv("Auto-launch", String(d.auto_launch))
    + kv("Data source", "REAL game telemetry (no synthetic data in this dashboard)");
  $("#set-mon").innerHTML = kv("Monitoring traffic", "separate from game traffic")
    + kv("Game bandwidth", "token-bucket enforced in the host")
    + kv("Monitoring rate", "1 Hz ingest · 2 s command poll");
  loadCmdLog();
}

/* ── boot ────────────────────────────────────────────────── */
// deep link: #room/CODE opens a room directly
function applyHash(){
  const h = location.hash.replace("#","");
  if(h.startsWith("room/")){ const c = h.slice(5);
    S.room = c; S.samples=[]; loadRooms(); loadDetail(); }
  else if(["rooms","history","compare","export","settings"].includes(h)){
    const b = document.querySelector(`#tabs button[data-v="${h}"]`); if(b) b.click();
  }
}
window.addEventListener("hashchange", applyHash);
connect(); loadRooms(); loadCmdLog(); applyHash();
setInterval(()=>{ loadRooms(); if(S.room) loadDetail(); }, 3000);
setInterval(loadCmdLog, 6000);
