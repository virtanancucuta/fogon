# Impresión POS + cocina absorbida por el admin — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el panel `/admin` imprima la comanda de cocina (auto, al confirmar) y la cuenta de cobro en impresora térmica 80 mm, maneje los estados de cocina (Empezar/Entregado), muestre en el mapa de mesas si la mesa está "En cocina" o "Entregada", y retire la app `/cocina`.

**Architecture:** Todo en `admin/index.html` (vanilla JS, sin framework). Impresión vía `window.print()` de un **iframe oculto** con `srcdoc` (CSS 80 mm). Auto-impresión por **realtime** (canal global persistente mientras el panel está abierto) + marca `impreso_at` anti-duplicado (idempotente). Una sola migración nueva (`0010`) que reusa las RPCs existentes (`cocina_comanda`, `cobrar_pedido`, `transicion_pedido`).

**Tech Stack:** HTML/CSS/JS vanilla, Supabase (Postgres + RLS + Realtime), GitHub Pages. Verificación con Playwright headless (`@playwright/cli` global, chromium `chromium_headless_shell-1223`) y `execute_sql` vía MCP Supabase — **el proyecto NO usa tests unitarios**; cada tarea cierra con verificación funcional concreta + commit. El gate final lo da Jorge en la térmica real.

**Convenciones del repo ya en uso (NO reinventar):** helpers `$`, `fmt`, `esc`, `codigo`, `hora`, `fecha`; `SB=window.supabaseClient`; sheets con `abrirSheet/cerrarSheet`; RPC vía `SB.rpc`. Push directo a `main` (patrón del proyecto). Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

**Nota de reconciliación (verificada en código):** la bandeja de domicilio **no** tiene hoy botón manual "En proceso" (los estados intermedios los avanzaba la app `/cocina` vía `cocina_comanda`, y el pedido se deriva con `recalc_estado_pedido`). Por tanto **no hay botón que quitar**: el avance intermedio simplemente pasa a hacerse desde la nueva sección **Cocina** del admin. El spec original decía "quitar el botón En proceso"; queda anulado por este hallazgo.

---

## Estructura de archivos

- **Modify:** `supabase/migrations/` → **Create:** `supabase/migrations/0010_impresion_comandas.sql` (columna `impreso_at` + RPC `marcar_comanda_impresa` + sellado del histórico).
- **Modify:** `admin/index.html` — único front tocado. Añade: constante `NEGOCIO`, iframe `#printframe`, módulo de impresión (`imprimir`, `tCocinaHTML`, `tCuentaHTML`), auto-impresión (`autoImprimir` + canal realtime global), tab y vista **Cocina** (`cargarCocina`/`renderCocina`/`avanzarComanda`/`reimprimirComanda`), botones "Imprimir cuenta" (mesa + domicilio), y ajuste de etiquetas en `ESTMESA`.
- **Sin tocar:** `cocina/index.html` (se retira del flujo desactivando el usuario `cocina@` al cerrar la auditoría; el archivo queda en el repo). `mesero/index.html`, `index.html` (storefront): intactos.

---

## Task 1: Migración 0010 — marca de impreso + RPC

**Files:**
- Create: `supabase/migrations/0010_impresion_comandas.sql`

- [ ] **Step 1: Escribir la migración**

Crear `supabase/migrations/0010_impresion_comandas.sql` con exactamente:

```sql
-- 0010_impresion_comandas — marca anti-duplicado para la impresion de comandas de cocina.
-- La comanda de cocina se auto-imprime cuando su pedido entra a cocina (confirmado/en_proceso/listo)
-- y aun no fue impresa. impreso_at sella el momento; recargar el panel no reimprime.

alter table comandas add column if not exists impreso_at timestamptz;

-- Sellar el historico existente para que el primer admin que entre NO reimprima pedidos viejos.
update comandas set impreso_at = now() where impreso_at is null;

-- Marca una comanda como impresa (idempotente: conserva el primer timestamp). Cualquier staff activo.
create or replace function marcar_comanda_impresa(p_comanda_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_rol rol_equipo; v_imp timestamptz;
begin
  select rol into v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol is null then raise exception 'solo personal autorizado'; end if;
  update comandas set impreso_at = coalesce(impreso_at, now())
    where id = p_comanda_id
    returning impreso_at into v_imp;
  if not found then raise exception 'comanda inexistente'; end if;
  return jsonb_build_object('ok', true, 'impreso_at', v_imp);
end; $$;
grant execute on function marcar_comanda_impresa(uuid) to authenticated;
```

- [ ] **Step 2: Aplicar la migración a Supabase**

Aplicar vía MCP `apply_migration` (project_id `kxacvooiedcuaohxqrbq`, name `0010_impresion_comandas`) con el cuerpo del Step 1.

- [ ] **Step 3: Verificar columna, sellado e idempotencia**

Ejecutar (MCP `execute_sql`, project `kxacvooiedcuaohxqrbq`):

```sql
select
  (select count(*) from comandas) as comandas,
  (select count(*) from comandas where impreso_at is null) as sin_imprimir;
```
Esperado: `sin_imprimir = 0` (histórico sellado).

Confirmar que la RPC existe:
```sql
select proname from pg_proc where proname = 'marcar_comanda_impresa';
```
Esperado: una fila.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0010_impresion_comandas.sql
git commit -m "Migracion 0010: impreso_at + marcar_comanda_impresa (anti-duplicado impresion)"
```

---

## Task 2: Módulo de impresión (iframe + plantillas de tickets)

**Files:**
- Modify: `admin/index.html` (HTML del panel + bloque `<script>`)

- [ ] **Step 1: Añadir el iframe oculto de impresión**

En `admin/index.html`, justo antes de `<script type="module" src="../supabase.js"></script>` (línea ~461), insertar:

```html
<!-- iframe oculto para imprimir tickets (no se ve en pantalla; imprime su propio documento) -->
<iframe id="printframe" title="Impresión" aria-hidden="true" style="position:fixed;left:-9999px;top:0;width:80mm;height:0;border:0"></iframe>
```

- [ ] **Step 2: Añadir la constante del negocio**

En el `<script>`, junto a las constantes (después de `const MEDIOS = {...};`, línea ~484), añadir:

```js
  const NEGOCIO = { nombre:'El Fogón de la Pesa', dir:'Estación Terpel · El Palustre, Atalaya — Cúcuta', tel:'322 225 9538' };
```

- [ ] **Step 3: Añadir el motor de impresión y las plantillas**

En el `<script>`, después de la línea `let SB=null, CATS=[], PRODS=[], DOMIS=[];` (línea ~493), añadir el bloque:

```js
  // ====== IMPRESIÓN (iframe oculto, ticket 80mm) ======
  // Cola secuencial: imprime un ticket a la vez (evita pisar el iframe en ráfagas).
  let _printQ = Promise.resolve();
  function imprimir(docHtml){
    _printQ = _printQ.then(()=> new Promise(res=>{
      const f = $('printframe'); if(!f){ res(); return; }
      let done=false; const fin=()=>{ if(done) return; done=true; res(); };
      f.onload = ()=>{ try{ f.contentWindow.focus(); f.contentWindow.print(); }catch(e){} setTimeout(fin, 700); };
      f.srcdoc = docHtml;
      setTimeout(fin, 4000); // salvavidas si onload no dispara
    }));
    return _printQ;
  }
  const TICKET_CSS = '@page{size:80mm auto;margin:0}'+
    '*{margin:0;padding:0;box-sizing:border-box}'+
    'body{width:80mm;padding:4mm 3mm;font-family:"Courier New",monospace;color:#000;font-size:12px;line-height:1.35}'+
    '.c{text-align:center}.b{font-weight:bold}.big{font-size:17px;font-weight:bold}'+
    '.hr{border-top:1px dashed #000;margin:5px 0}.hr2{border-top:2px solid #000;margin:5px 0}'+
    '.row{display:flex;justify-content:space-between;gap:6px}'+
    '.it{display:flex;gap:6px;margin:2px 0}.it .q{font-weight:bold;min-width:26px}'+
    '.tot{display:flex;justify-content:space-between;font-size:16px;font-weight:bold;margin-top:4px}'+
    '.sm{font-size:10px}.mt{margin-top:4px}.up{text-transform:uppercase}';
  function docTicket(inner){ return '<!doctype html><html><head><meta charset="utf-8"><style>'+TICKET_CSS+'</style></head><body>'+inner+'</body></html>'; }
  function lineaTipo(p){
    if(p && p.tipo==='mesa') return 'MESA '+esc(p.mesa_numero||'?');
    return 'DOMICILIO';
  }
  // Comanda de cocina (SIN precios). c: {tanda,pedido_id}, p: pedido, items:[{qty,nombre_snap}]
  function tCocinaHTML(c, p, items){
    const ronda = c.tanda>1 ? ' · RONDA '+c.tanda : '';
    let its = (items||[]).map(x=>'<div class="it"><span class="q">'+(x.qty||1)+'x</span><span>'+esc(x.nombre_snap)+'</span></div>').join('');
    if(!its) its='<div class="sm">Sin ítems</div>';
    const notas = (p && p.notas) ? '<div class="hr"></div><div class="sm b">NOTAS:</div><div class="sm">'+esc(p.notas)+'</div>' : '';
    return docTicket(
      '<div class="c big">'+lineaTipo(p)+'</div>'+
      '<div class="c sm">COMANDA '+esc(codigo(c.pedido_id))+ronda+'</div>'+
      '<div class="c sm">'+hora(c.created_at||new Date().toISOString())+'</div>'+
      '<div class="hr2"></div>'+ its +'<div class="hr2"></div>'+ notas +
      '<div class="c sm mt">— El Fogón de la Pesa —</div>'
    );
  }
  // Cuenta de cobro (CON precios). p: pedido con comanda_items aplanados en `lineas`, total, medio
  function tCuentaHTML(p, lineas, total, medio){
    let its = (lineas||[]).map(x=>{
      const val = x.precio_snap>0 ? fmt(x.subtotal) : 'En el local';
      return '<div class="row"><span>'+(x.qty||1)+'x '+esc(x.nombre_snap)+'</span><span>'+val+'</span></div>';
    }).join('');
    if(!its) its='<div class="sm">Sin ítems</div>';
    const mp = medio ? '<div class="row sm mt"><span>Pago</span><span>'+esc(MEDIOS[medio]||medio)+'</span></div>' : '';
    return docTicket(
      '<div class="c b up">'+esc(NEGOCIO.nombre)+'</div>'+
      '<div class="c sm">'+esc(NEGOCIO.dir)+'</div>'+
      '<div class="c sm">Tel '+esc(NEGOCIO.tel)+'</div>'+
      '<div class="hr"></div>'+
      '<div class="row sm"><span>'+lineaTipo(p)+'</span><span>'+esc(codigo(p.id))+'</span></div>'+
      '<div class="sm">'+fecha(new Date().toISOString())+'</div>'+
      '<div class="hr2"></div>'+ its +'<div class="hr"></div>'+
      '<div class="tot"><span>TOTAL</span><span>'+fmt(total)+'</span></div>'+ mp +
      '<div class="c sm mt">¡Gracias por su visita!</div>'
    );
  }
```

- [ ] **Step 4: Smoke de plantillas (Playwright headless)**

Crear archivo temporal `/tmp/fogon_print_smoke.html` con un `<script>` que copie `TICKET_CSS`, `docTicket`, `tCocinaHTML`, `tCuentaHTML`, helpers `esc/fmt/codigo/hora/fecha` y `MEDIOS/NEGOCIO`, y registre en `window.__out` el HTML generado para una comanda y una cuenta de ejemplo. Abrir con el chromium headless y verificar que ambos HTML contienen los textos esperados.

Comando (PowerShell, ajusta la ruta del runner si difiere):
```bash
node -e "const html=require('fs').readFileSync('/tmp/fogon_print_smoke.html','utf8'); console.log(html.includes('tCocinaHTML')?'ok-archivo':'falta')"
```
Verificación funcional alternativa (más simple y suficiente): tras desplegar la Task 5, ejecutar el smoke E2E de la Task 9. Si se prefiere validar aquí, abrir `/tmp/fogon_print_smoke.html` en chromium headless y comprobar `window.__out.cocina` incluye `"MESA 3"` y `"2x"`, y `window.__out.cuenta` incluye `"TOTAL"`, `"El Fogón de la Pesa"` y `"$30.000"`.
Esperado: ambas cadenas presentes, 0 errores de consola.

- [ ] **Step 5: Commit**

```bash
git add admin/index.html
git commit -m "Impresion: iframe oculto + plantillas ticket cocina/cuenta (80mm)"
```

---

## Task 3: Realtime a canal global persistente

Hoy el realtime (`canal 'bandeja'`) solo escucha `pedidos` y vive por-tab (se desuscribe al salir de pedidos/mesas). La auto-impresión y la vista Cocina necesitan un canal **siempre activo mientras el panel está abierto** que escuche `pedidos` **y** `comandas`.

**Files:**
- Modify: `admin/index.html`

- [ ] **Step 1: Reescribir `suscribir`/`desuscribir` como canal global (pedidos + comandas)**

Reemplazar el bloque actual (líneas ~614-621):

```js
  // ---- realtime ----
  function suscribir(){
    if(canal) return;
    canal = SB.channel('bandeja').on('postgres_changes', {event:'*', schema:'public', table:'pedidos'}, ()=>{
      clearTimeout(reloadT); reloadT=setTimeout(()=>{ if(TAB==='pedidos') refrescarBandeja(); else if(TAB==='mesas') refrescarMesas(); }, 400);
    }).subscribe();
  }
  function desuscribir(){ if(canal){ SB.removeChannel(canal); canal=null; } }
```

por:

```js
  // ---- realtime (canal global: vive mientras el panel está abierto) ----
  function onCambioRT(){
    clearTimeout(reloadT);
    reloadT=setTimeout(()=>{
      if(TAB==='pedidos') refrescarBandeja();
      else if(TAB==='mesas') refrescarMesas();
      else if(TAB==='cocina') refrescarCocina();
      autoImprimir(); // imprime comandas nuevas no impresas (mesa al instante, domicilio al confirmar)
    }, 450);
  }
  function suscribir(){
    if(canal) return;
    canal = SB.channel('panel-rt')
      .on('postgres_changes', {event:'*', schema:'public', table:'pedidos'}, onCambioRT)
      .on('postgres_changes', {event:'*', schema:'public', table:'comandas'}, onCambioRT)
      .subscribe();
  }
  function desuscribir(){ if(canal){ SB.removeChannel(canal); canal=null; } }
```

- [ ] **Step 2: Suscribir al entrar, desuscribir al salir (no por-tab)**

En `entrar(rol)` (línea ~520), añadir la suscripción y un catch-up de impresión. Reemplazar:
```js
  function entrar(rol){ $('quien').textContent = rol==='admin'?'Administradora':('Equipo · '+rol); mostrarPanel(); irA('pedidos'); }
```
por:
```js
  function entrar(rol){ $('quien').textContent = rol==='admin'?'Administradora':('Equipo · '+rol); mostrarPanel(); suscribir(); autoImprimir(); irA('pedidos'); }
```

- [ ] **Step 3: Quitar la des/suscripción por-tab en `irA` y en `cargarPedidos`/`cargarMesas`**

En `irA(tab)` (línea ~524) eliminar la primera línea del cuerpo:
```js
    if(tab!=='pedidos' && tab!=='mesas') desuscribir();
```
(El canal ahora es global; `irA` no toca la suscripción.)

En `cargarPedidos()` (línea ~547) eliminar la llamada `suscribir();` (queda `refrescarBandeja();`).
En `cargarMesas()` (línea ~958) eliminar la llamada `suscribir();` (queda `refrescarMesas();`).

(`salir()` ya llama `desuscribir()` — se mantiene.)

- [ ] **Step 4: Verificar realtime sigue vivo (Playwright headless)**

Smoke: iniciar sesión como `admin`/`fogon` (inyectando sesión, patrón del proyecto), insertar por `execute_sql` un pedido de mesa de prueba y confirmar que la bandeja/mesas se refresca sin recargar y sin errores de consola. (Se valida junto con la Task 4/9.) Mínimo aquí: cargar el panel, comprobar `0 errores de consola` y que `window` no lanza por `autoImprimir`/`refrescarCocina` aún no definidos → **define stubs si esta task se ejecuta antes que la 4 y la 5**: añadir temporalmente al final del script `window.autoImprimir=window.autoImprimir||function(){}; window.refrescarCocina=window.refrescarCocina||function(){};` y quitarlos cuando existan las funciones reales.

> Nota de orden: para evitar referencias indefinidas, ejecutar Task 4 y Task 5 inmediatamente después de la 3 antes de desplegar. `autoImprimir` se define en Task 4 y `refrescarCocina` en Task 5.

- [ ] **Step 5: Commit**

```bash
git add admin/index.html
git commit -m "Realtime: canal global persistente (pedidos+comandas) en vez de por-tab"
```

---

## Task 4: Auto-impresión de comandas no impresas

**Files:**
- Modify: `admin/index.html`

- [ ] **Step 1: Añadir `autoImprimir`**

Después del módulo de impresión (final de la Task 2, tras `tCuentaHTML`), añadir:

```js
  // ====== AUTO-IMPRESIÓN ======
  // Imprime las comandas cuyo pedido ya entró a cocina (confirmado/en_proceso/listo) y no fueron impresas.
  // Idempotente: marca impreso_at; recargar no reimprime. Cubre mesa (nace confirmada) y domicilio (al confirmar).
  let autoBusy=false;
  async function autoImprimir(){
    if(autoBusy || !SB) return; autoBusy=true;
    try{
      const { data, error } = await SB.from('comandas')
        .select('id,tanda,created_at,pedido_id, pedidos(tipo,mesa_numero,estado,notas), comanda_items(qty,nombre_snap)')
        .is('impreso_at', null).order('created_at',{ascending:true});
      if(error) return;
      const pend=(data||[]).filter(c=>c.pedidos && ['confirmado','en_proceso','listo'].includes(c.pedidos.estado));
      for(const c of pend){
        await imprimir(tCocinaHTML(c, c.pedidos, c.comanda_items||[]));
        try{ await SB.rpc('marcar_comanda_impresa',{ p_comanda_id:c.id }); }catch(e){}
      }
    } finally { autoBusy=false; }
  }
```

- [ ] **Step 2: Verificar auto-impresión + marca (Playwright headless + SQL)**

1. Sembrar un pedido de mesa de prueba en `confirmado` con 1 comanda `pendiente` no impresa, vía `execute_sql` (usar `crear_pedido_mesa` no es posible sin sesión RPC; insertar directo con SQL es aceptable para la prueba — recordar limpiarlo). Ejemplo:
```sql
-- prueba: dejar una comanda no impresa en una mesa
with p as (
  insert into pedidos (tipo,canal,estado,mesa_numero,total)
  values ('mesa','salon','confirmado','PRUEBA-IMP',15000) returning id
), c as (
  insert into comandas (pedido_id,tanda,estado) select id,1,'pendiente' from p returning id, pedido_id
)
insert into comanda_items (comanda_id,nombre_snap,precio_snap,qty,subtotal)
select c.id,'Caldo Prueba',15000,1,15000 from c;
```
2. En headless: abrir `/admin`, inyectar sesión admin, esperar a que cargue. En headless `print()` no bloquea. Tras ~3s, verificar por `execute_sql`:
```sql
select estado, impreso_at is not null as impresa from comandas
where pedido_id in (select id from pedidos where mesa_numero='PRUEBA-IMP');
```
Esperado: `impresa = true` (autoImprimir la marcó). 0 errores de consola.
3. **Limpiar** la prueba:
```sql
delete from comanda_items where comanda_id in (select id from comandas where pedido_id in (select id from pedidos where mesa_numero='PRUEBA-IMP'));
delete from comandas where pedido_id in (select id from pedidos where mesa_numero='PRUEBA-IMP');
delete from pedidos where mesa_numero='PRUEBA-IMP';
```

- [ ] **Step 3: Commit**

```bash
git add admin/index.html
git commit -m "Auto-impresion: imprime y marca comandas no impresas en cocina (realtime + catch-up)"
```

---

## Task 5: Tab y vista "Cocina" en el admin

**Files:**
- Modify: `admin/index.html` (nav + vista + funciones)

- [ ] **Step 1: Añadir el botón de tab "Cocina" al nav**

En `<nav class="tabs" id="tabs">` (línea ~310), insertar como **primer** botón (antes de "Pedidos") para que sea lo primero en caja, y quitar la clase `active` de "Pedidos":

```html
    <button data-tab="cocina" class="active" onclick="irA('cocina')">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 2v7M11 2v7M9 9v11M7 9a2 2 0 0 0 4 0M17 2c-1.5 1-2 3-2 6s.5 4 2 4 2-1 2-4-.5-5-2-6zM17 12v8"/></svg>
      Cocina
    </button>
```
Y en el botón `data-tab="pedidos"` quitar `class="active"` (queda `<button data-tab="pedidos" onclick="irA('pedidos')">`).

- [ ] **Step 2: Arrancar en la tab Cocina**

En `entrar(rol)` (modificado en Task 3), cambiar el `irA('pedidos')` final por `irA('cocina')`:
```js
  function entrar(rol){ $('quien').textContent = rol==='admin'?'Administradora':('Equipo · '+rol); mostrarPanel(); suscribir(); autoImprimir(); irA('cocina'); }
```
Y en `irA(tab)` añadir el routing (en el `if/else`, línea ~528):
```js
    if(tab==='cocina') cargarCocina();
    else if(tab==='pedidos') cargarPedidos();
    else if(tab==='mesas') cargarMesas();
    else if(tab==='productos') cargarProductos();
    else if(tab==='clientes') cargarClientes();
    else cargarVentas();
```

- [ ] **Step 3: Añadir estilos de la vista Cocina**

En el `<style>`, antes de `/* nav inferior */` (línea ~190), añadir:

```css
  /* cocina (comandas en el admin) */
  .ck-grid{display:grid;grid-template-columns:1fr;gap:12px}
  @media(min-width:560px){.ck-grid{grid-template-columns:1fr 1fr}}
  .ck{background:var(--crema-card);border:2px solid var(--marron-osc);border-radius:16px;overflow:hidden;box-shadow:0 4px 0 rgba(58,30,16,.08)}
  .ck.proc{border-color:#1e40af}
  .ck-h{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 13px;border-bottom:2px solid var(--marron-osc)}
  .ck.new .ck-h{background:var(--amarillo-suave)}.ck.proc .ck-h{background:#dbeafe}
  .ck-cod{font-family:'Anton',sans-serif;font-size:1.1rem;color:var(--carbon)}
  .ck-ronda{margin-left:6px;font-family:'Oswald',sans-serif;font-weight:600;font-size:.55rem;text-transform:uppercase;background:var(--rojo);color:#fff;padding:2px 6px;border-radius:30px}
  .ck-tipo{font-family:'Oswald',sans-serif;font-weight:600;font-size:.8rem;text-transform:uppercase;color:var(--rojo)}
  .ck-b{padding:10px 13px}
  .ck-it{display:flex;gap:8px;padding:3px 0;font-size:.95rem}
  .ck-it .q{font-family:'Anton',sans-serif;color:var(--rojo);min-width:30px}
  .ck-meta{display:flex;align-items:center;justify-content:space-between;gap:8px;font-family:'Oswald',sans-serif;font-size:.7rem;color:var(--gris);margin-top:8px}
  .ck-imp{color:var(--verde-osc)}
  .ck-acts{display:flex;gap:0;border-top:2px solid var(--marron-osc)}
  .ck-act{flex:1 1 0;border:none;font-family:'Oswald',sans-serif;font-weight:700;text-transform:uppercase;letter-spacing:.03em;font-size:.92rem;padding:14px;cursor:pointer;color:#fff}
  .ck-act.empezar{background:#1e40af}.ck-act.entregar{background:var(--verde)}
  .ck-act.repr{flex:0 0 auto;background:#fff;color:var(--marron-osc);border-left:2px solid var(--marron-osc);padding:14px 16px}
  .ck-act:active{filter:brightness(.94)}
  .ck-sec{font-family:'Anton',sans-serif;font-size:1rem;color:var(--marron-osc);text-transform:uppercase;margin:14px 2px 6px}
```

- [ ] **Step 4: Añadir las funciones de la vista Cocina**

Después de `autoImprimir` (Task 4), añadir:

```js
  // ====== COCINA (comandas: Empezar/Entregado + reimprimir) ======
  let CK=[];
  function cargarCocina(){
    setView('<div class="view-head"><div><div class="view-title">Cocina</div><div class="view-sub">Comandas en tiempo real · se imprimen solas</div></div></div><div id="ckvw"><div class="loading">Cargando comandas…</div></div>');
    refrescarCocina();
  }
  async function refrescarCocina(){
    const cont=$('ckvw'); if(!cont) return;
    const { data, error } = await SB.from('comandas')
      .select('id,tanda,estado,created_at,impreso_at,pedido_id, pedidos(tipo,mesa_numero,estado,notas), comanda_items(qty,nombre_snap)')
      .in('estado',['pendiente','en_proceso']).order('created_at',{ascending:true});
    if(!$('ckvw')) return;
    if(error){ cont.innerHTML='<div class="empty">No se pudo cargar.</div>'; return; }
    CK=(data||[]).filter(c=>c.pedidos && c.pedidos.estado!=='cancelado');
    if(CK.length===0){ cont.innerHTML='<div class="empty">No hay comandas pendientes 🍲</div>'; return; }
    const nuevas=CK.filter(c=>c.estado==='pendiente'), proc=CK.filter(c=>c.estado==='en_proceso');
    let html='';
    if(nuevas.length){ html+='<div class="ck-sec">Por preparar ('+nuevas.length+')</div><div class="ck-grid">'+nuevas.map(c=>ckCard(c,'new')).join('')+'</div>'; }
    if(proc.length){ html+='<div class="ck-sec">En cocina ('+proc.length+')</div><div class="ck-grid">'+proc.map(c=>ckCard(c,'proc')).join('')+'</div>'; }
    cont.innerHTML=html;
  }
  function ckCard(c, cls){
    const p=c.pedidos||{};
    const its=(c.comanda_items||[]).map(x=>'<div class="ck-it"><span class="q">'+(x.qty||1)+'×</span><span>'+esc(x.nombre_snap)+'</span></div>').join('') || '<div class="ck-it">Sin ítems</div>';
    const ronda=c.tanda>1?'<span class="ck-ronda">Ronda '+c.tanda+'</span>':'';
    const imp=c.impreso_at?('Impreso '+hora(c.impreso_at)):'Sin imprimir';
    const act=c.estado==='pendiente'
      ? '<button class="ck-act empezar" onclick="avanzarComanda(\''+c.id+'\',\'en_proceso\')">Empezar</button>'
      : '<button class="ck-act entregar" onclick="avanzarComanda(\''+c.id+'\',\'entregado\')">Entregado</button>';
    return '<div class="ck '+cls+'"><div class="ck-h"><span class="ck-cod">'+esc(codigo(c.pedido_id))+ronda+'</span><span class="ck-tipo">'+esc(lineaTipo(p))+'</span></div>'+
      '<div class="ck-b">'+its+'<div class="ck-meta"><span>Recibido '+hora(c.created_at)+'</span><span class="ck-imp">'+imp+'</span></div></div>'+
      '<div class="ck-acts">'+act+'<button class="ck-act repr" onclick="reimprimirComanda(\''+c.id+'\')">⟳</button></div></div>';
  }
  async function avanzarComanda(id, a){
    try{ const { error }=await SB.rpc('cocina_comanda',{ p_comanda_id:id, p_a:a }); if(error) throw error; refrescarCocina(); }
    catch(e){ alert('No se pudo: '+(e.message||e)); }
  }
  async function reimprimirComanda(id){
    const c=CK.find(x=>x.id===id); if(!c) return;
    await imprimir(tCocinaHTML(c, c.pedidos||{}, c.comanda_items||[]));
    try{ await SB.rpc('marcar_comanda_impresa',{ p_comanda_id:id }); }catch(e){}
    refrescarCocina();
  }
```

- [ ] **Step 5: Verificar la vista Cocina (Playwright headless)**

Sembrar una comanda de mesa de prueba (como en Task 4 Step 2). Abrir `/admin` como admin, ir a la tab **Cocina**: debe verse la tarjeta con el código, ítems, badge "Impreso HH:MM" (la auto-impresión ya la marcó) y botones **Empezar** y **⟳**. Pulsar **Empezar** (vía `page.click`) → la tarjeta pasa a la sección "En cocina" con botón **Entregado**. Verificar por SQL:
```sql
select estado from comandas where pedido_id in (select id from pedidos where mesa_numero='PRUEBA-IMP');
```
Esperado: `en_proceso`. Luego limpiar la prueba (SQL del Task 4 Step 2.3). 0 errores de consola.

- [ ] **Step 6: Commit**

```bash
git add admin/index.html
git commit -m "Cocina en el admin: vista de comandas (Empezar/Entregado + reimprimir + badge impreso)"
```

---

## Task 6: Botón "Imprimir cuenta" en la hoja de Mesa

**Files:**
- Modify: `admin/index.html`

- [ ] **Step 1: Añadir el botón en la hoja de mesa**

En la hoja `mt-sheet`, dentro de `mesaAbrir(pedidoId)` (línea ~998), el cuerpo se arma en `$('mt-body').innerHTML=...`. Añadir un botón de impresión al final de ese innerHTML. Reemplazar la línea:
```js
    $('mt-body').innerHTML='<div class="ped-items" style="border-top:none;padding-top:0">'+(its||'<div class="ped-it"><span>Sin ítems</span></div>')+'</div><div class="ped-tot"><span>Total</span><b>'+fmt(p.total)+'</b></div>';
```
por:
```js
    $('mt-body').innerHTML='<div class="ped-items" style="border-top:none;padding-top:0">'+(its||'<div class="ped-it"><span>Sin ítems</span></div>')+'</div><div class="ped-tot"><span>Total</span><b>'+fmt(p.total)+'</b></div>'+
      '<button class="btn-sm" type="button" style="width:100%;margin-top:12px" onclick="imprimirCuentaMesa()">Imprimir cuenta</button>';
```

- [ ] **Step 2: Añadir `imprimirCuentaMesa`**

Después de `mesaAbrir` (línea ~1004), añadir:

```js
  function imprimirCuentaMesa(){
    const p=MESA_PEDS.find(x=>x.id===mtPedido); if(!p) return;
    const lineas=(p.comandas||[]).flatMap(c=>c.comanda_items||[]);
    imprimir(tCuentaHTML({id:p.id, tipo:'mesa', mesa_numero:p.mesa_numero}, lineas, p.total, p.medio_pago));
  }
```
Nota: `MESA_PEDS` trae `comandas(comanda_items(nombre_snap,qty))` (ver `refrescarMesas`, línea ~969). Para que la cuenta lleve precios, ampliar ese select: en `refrescarMesas` cambiar `comandas(comanda_items(nombre_snap,qty))` por `comandas(comanda_items(nombre_snap,qty,precio_snap,subtotal))`.

- [ ] **Step 3: Verificar (Playwright headless)**

Con una mesa de prueba abierta (estado `confirmado`/`listo`), abrir su hoja, pulsar "Imprimir cuenta". En headless `print()` no bloquea; verificar 0 errores de consola y que `window` no lanza. (La validación visual del ticket la hace Jorge en la térmica.) Confirmar también que el `select` ampliado de `refrescarMesas` no rompe el mapa (mesas siguen pintando).

- [ ] **Step 4: Commit**

```bash
git add admin/index.html
git commit -m "Cuenta de cobro imprimible desde la hoja de mesa"
```

---

## Task 7: Botón "Imprimir cuenta" en domicilios

**Files:**
- Modify: `admin/index.html`

- [ ] **Step 1: Añadir el botón en las tarjetas de domicilio**

En `botonesDe(p)` (línea ~575), añadir un botón "Imprimir cuenta" para los estados ya confirmados. Reemplazar todo el cuerpo de `botonesDe` por:

```js
  function botonesDe(p){
    const e=p.estado, id=p.id;
    const imprimible = (e==='confirmado'||e==='en_proceso'||e==='listo'||e==='enviado');
    const btnImp = imprimible ? '<button class="act alt" onclick="imprimirCuentaDom(\''+id+'\')">Imprimir cuenta</button>' : '';
    if(e==='por_confirmar') return '<div class="ped-acts">'+
      '<button class="act main" onclick="confirmarAbrir(\''+id+'\')">Confirmar y cobrar</button>'+
      '<button class="act alt" onclick="modificarAbrir(\''+id+'\')">Modificar</button>'+
      '<button class="act danger" onclick="cancelar(\''+id+'\')">Cancelar</button></div>';
    if(e==='confirmado' || e==='en_proceso') return '<div class="ped-acts">'+
      '<div class="act-note">'+(e==='en_proceso'?'Cocina preparando…':'En cola de cocina…')+'</div>'+
      btnImp+'<button class="act danger" onclick="cancelar(\''+id+'\')">Cancelar</button></div>';
    if(e==='listo') return '<div class="ped-acts">'+
      '<button class="act main" onclick="enviarAbrir(\''+id+'\')">Enviar</button>'+
      btnImp+'<button class="act danger" onclick="cancelar(\''+id+'\')">Cancelar</button></div>';
    if(e==='enviado') return '<div class="ped-acts">'+btnImp+'</div>';
    return '';
  }
```

- [ ] **Step 2: Añadir `imprimirCuentaDom`**

La bandeja ya trae `comandas(comanda_items(producto_id,nombre_snap,precio_snap,qty,subtotal))` y `clientes(nombre,celular)`, `total`, `medio_pago` (ver `refrescarBandeja`, línea ~561). Guardar la última data renderizada para reusarla. En `renderBandeja(peds)` (línea ~589), al inicio del cuerpo añadir `BANDEJA_CACHE = peds;` y declarar la variable junto a las de pedidos (línea ~545): `let FILTRO='por_confirmar', canal=null, reloadT=null, BANDEJA_CACHE=[];`.

Luego, después de `renderBandeja` (línea ~612), añadir:
```js
  function imprimirCuentaDom(id){
    const p=(BANDEJA_CACHE||[]).find(x=>x.id===id); if(!p) return;
    const lineas=(p.comandas||[]).flatMap(c=>c.comanda_items||[]);
    imprimir(tCuentaHTML({id:p.id, tipo:'domicilio'}, lineas, p.total, p.medio_pago));
  }
```

- [ ] **Step 3: Verificar (Playwright headless)**

Ir a la bandeja de domicilio, filtro "En cocina" o "Enviados hoy" (donde haya un pedido), abrir y pulsar "Imprimir cuenta". Verificar 0 errores de consola y que `imprimirCuentaDom` encuentra el pedido en `BANDEJA_CACHE`. (Hay un demo `#00D2` enviado y `#4075` por confirmar; usar uno confirmado/enviado.)

- [ ] **Step 4: Commit**

```bash
git add admin/index.html
git commit -m "Cuenta de cobro imprimible desde la bandeja de domicilios"
```

---

## Task 8: Estado visible por mesa (En cocina / Entregado a la mesa)

**Files:**
- Modify: `admin/index.html`

- [ ] **Step 1: Ajustar etiquetas de `ESTMESA`**

Reemplazar (línea ~957):
```js
  const ESTMESA={confirmado:{t:'En cocina',cls:'cocina'},en_proceso:{t:'En proceso',cls:'proc'},listo:{t:'Servido · por cobrar',cls:'servido'}};
```
por:
```js
  const ESTMESA={confirmado:{t:'En cola de cocina',cls:'cocina'},en_proceso:{t:'En cocina',cls:'proc'},listo:{t:'Entregado a la mesa',cls:'servido'}};
```
(Color: `cocina`=azul, `proc`=naranja, `servido`=morado — ya definidos en CSS. "En cocina" = la cocina está preparando; "Entregado a la mesa" = servido, por cobrar.)

- [ ] **Step 2: Verificar (Playwright headless)**

Con una mesa de prueba en `en_proceso`, ir a la tab **Mesas**: la mesa muestra el texto **"En cocina"**; al marcar la comanda como **Entregado** desde la tab Cocina, la mesa pasa a **"Entregado a la mesa"** (refresco por realtime). Verificar por inspección del DOM (`.mesa-est`) y 0 errores. Limpiar la prueba.

- [ ] **Step 3: Commit**

```bash
git add admin/index.html
git commit -m "Mesas: etiquetas claras En cocina / Entregado a la mesa"
```

---

## Task 9: Verificación E2E + despliegue + cierre

**Files:** ninguno (verificación y despliegue)

- [ ] **Step 1: Push y espera de GitHub Pages**

```bash
git push origin main
```
Esperar ~1 min al deploy de Pages.

- [ ] **Step 2: Smoke E2E completo (Playwright headless contra el sitio live)**

Patrón del proyecto (inyectar sesión admin en `localStorage` clave `sb-kxacvooiedcuaohxqrbq-auth-token` + abrir `/admin`). Recorrido:
1. **Mesa nueva → auto-imprime:** sembrar un pedido de mesa `confirmado` con comanda `pendiente` no impresa (SQL). Con el panel abierto, esperar el realtime → verificar por SQL `impreso_at is not null` para esa comanda.
2. **No reimprime al recargar:** recargar el panel → la misma comanda NO cambia su `impreso_at` (sigue el primer timestamp).
3. **Empezar/Entregado:** desde tab Cocina, Empezar → `en_proceso`; Entregado → `entregado` y pedido `listo` (verificar por SQL).
4. **Mesas:** la mesa muestra "En cocina" y luego "Entregado a la mesa".
5. **Cuenta de cobro:** abrir la mesa, "Imprimir cuenta" → 0 errores.
6. **Limpieza:** borrar el pedido de prueba (SQL del Task 4).
Esperado: todos los pasos PASS, 0 errores de consola.

- [ ] **Step 3: Desactivar el usuario `cocina@` (solo cuando Jorge confirme que terminó de auditar `/cocina`)**

⚠️ No ejecutar hasta el OK de Jorge. Cuando lo dé:
```sql
update empleados set activo=false where rol='cocina';
```
(El login de cocina dejará de validar como staff. Reversible con `activo=true`.)

- [ ] **Step 4: Gate de Jorge (validación física)**

Jorge prueba en la PC de caja con la impresora térmica real:
- Configurar el acceso directo de Chrome con `--kiosk-printing` (documentarlo: `chrome.exe --kiosk-printing https://virtanancucuta.github.io/fogon/admin/`).
- Mesera manda un pedido → sale la comanda sola en 80 mm.
- Cobrar mesa → imprime la cuenta con total correcto.
- Confirma look y ancho. Solo entonces se cierra la fase.

- [ ] **Step 5: Commit de cierre (si hubo ajustes) y actualización de memoria**

Tras el OK de Jorge, actualizar el archivo de memoria del proyecto (`project_fogon_menu_digital.md`) con el cierre de la fase de impresión.

---

## Self-review (cobertura del spec)

- Retiro de `/cocina` + admin maneja estados → **Task 5** (vista Cocina con `cocina_comanda`) + **Task 9 Step 3** (desactivar `cocina@`). ✓
- Impresión 80 mm con `window.print()` + iframe + kiosk → **Task 2** + nota kiosk en **Task 9 Step 4**. ✓
- Estación de caja + auto-impresión por realtime + `impreso_at` + reimprimir → **Task 1, 3, 4** (auto) + **Task 5** (badge + ⟳ reimprimir). ✓
- Dos tickets (comanda sin precios / cuenta con precios) → **Task 2** (`tCocinaHTML`/`tCuentaHTML`), cuenta en **Task 6** (mesa) y **Task 7** (domicilio). ✓
- Migración única `0010` (`impreso_at` + `marcar_comanda_impresa`) → **Task 1**. ✓
- Mesera intacta; estados se derivan → no se toca `mesero/`; `recalc_estado_pedido` ya existe. ✓
- Estado visible por mesa (En cocina / Entregado a la mesa) → **Task 8**. ✓
- "Quitar botón En proceso de domicilio" → **anulado** (no existe tal botón; documentado en cabecera y Task 7 conserva la bandeja). ✓

Sin placeholders. Nombres consistentes: `imprimir`, `tCocinaHTML`, `tCuentaHTML`, `autoImprimir`, `refrescarCocina`, `avanzarComanda`, `reimprimirComanda`, `imprimirCuentaMesa`, `imprimirCuentaDom`, `BANDEJA_CACHE`, `MESA_PEDS`, `ESTMESA`.
