import { useEffect, useRef, useState } from 'react'
import { Link, Navigate, Route, Routes, useNavigate } from 'react-router-dom'
import { Activity, ArrowDownToLine, ArrowLeft, ArrowRight, ArrowUpFromLine, AudioLines, BadgeCheck, CarFront, Check, CircleParking, Clock3, Copy, DoorOpen, Gauge, LockKeyhole, LogOut, Menu, Moon, ParkingCircle, Plus, RotateCcw, Settings2, ShieldCheck, Sun, Ticket, TriangleAlert, Wifi, WifiOff, X } from 'lucide-react'
import { useParking } from '../hooks/useParking'
import { isLocalSupabase, isSupabaseConfigured, supabase } from '../lib/supabase'
import { localResetFailureMessage } from '../lib/resetError'
import { parkingStore } from '../services/parkingStore'
import { supabaseParking, type TerminalOperationProgress } from '../services/supabaseParking'
import { migrateLegacyTerminalCredential, restoreTerminalCredential, terminalCredentialStorage, validateAndStoreTerminalCredential } from '../services/terminalCredentials'
import { CAPACITY, localDate, type Direction, type VehicleType } from '../domain/parking'
import { normalizeReservationTokenInput } from '../domain/reservationToken'

const vehicleLabels: Record<VehicleType, string> = { regular: 'Regular', reserved: 'Reservado', temporary: 'Temporal' }

function gateStatus(state: ReturnType<typeof useParking>, direction: Direction) {
  const operation = state.operations[direction]
  if (!operation) return 'Cerrada'
  if (state.mode === 'simulation') return 'Secuencia simulada en curso'
  if (state.sensors[direction]) return 'Vehículo detectado'
  if (operation.status === 'detected') return 'Sensor libre · validando 500 ms'
  return 'Orden enviada · esperando confirmación'
}

function sensorStatus(state: ReturnType<typeof useParking>, direction: Direction, now: number) {
  if (state.mode === 'simulation') return state.sensors[direction] ? 'Detectando' : 'Libre'
  const updated = state.sensorUpdatedAt ? Date.parse(state.sensorUpdatedAt) : 0
  if (!updated || now - updated > 30_000 || !state.physicalConnected) return 'Sin comunicación'
  return state.sensors[direction] ? 'Detectando' : 'Libre'
}

function physicalControllerOnline(state: ReturnType<typeof useParking>, now: number) {
  const heartbeat = state.physicalLastHeartbeatAt ? Date.parse(state.physicalLastHeartbeatAt) : 0
  return state.mode === 'hardware' && state.physicalConnected && Boolean(heartbeat) && now - heartbeat <= 30_000
}

function lightingStatus(state: ReturnType<typeof useParking>, now: number) {
  if (state.mode === 'simulation') return `${state.night ? 'Noche' : 'Día'} · Luces blancas ${state.night ? 'encendidas' : 'apagadas'}`
  const updated = state.sensorUpdatedAt ? Date.parse(state.sensorUpdatedAt) : 0
  const lighting = state.lightingTelemetry
  if (!physicalControllerOnline(state, now) || !updated || now - updated > 30_000 || !lighting) return 'Sin comunicación'
  const ldr = lighting.ldrNight ? 'Noche' : 'Día'
  const whites = lighting.whiteLightsOn ? 'encendidas' : 'apagadas'
  const rgb = lighting.rgbState === 'off' ? 'apagado' : lighting.rgbState
  return lighting.manual
    ? `Control manual activo · LDR: ${ldr} · luces blancas ${whites} · RGB ${rgb}`
    : `${ldr} · Luces blancas ${whites} · RGB ${rgb}`
}

function App() {
  return <Routes>
    <Route path="/" element={<Home />} />
    <Route path="/entrada" element={<Terminal direction="entry" />} />
    <Route path="/salida" element={<Terminal direction="exit" />} />
    <Route path="/admin/login" element={<Login />} />
    <Route path="/admin" element={<Admin />} />
    <Route path="*" element={<Navigate to="/" replace />} />
  </Routes>
}

function Home() {
  const state = useParking()
  return <main className="home-screen"><header className="brand-row"><Brand /><span className="live-tag"><i /> Sistema operativo</span></header>
    <section className="home-hero"><div className="hero-copy"><p className="eyebrow">PLATAFORMA DE CONTROL · 01</p><h1>Estacionamiento<br /><em>inteligente.</em></h1><p className="body-copy">Una maqueta, tres experiencias conectadas. Elegí la interfaz para comenzar la demostración.</p><div className="summary-pills"><span><CarFront size={16} /> {state.counts.regular + state.counts.reserved + state.counts.temporary} vehículos adentro</span><span><ParkingCircle size={16} /> {CAPACITY.regular - state.counts.regular} plazas libres</span></div></div>
    <div className="lane-illustration" aria-hidden="true"><div className="lane-label">ACCESO PRINCIPAL</div><div className="road"><div className="road-markings"/><div className="barrier-pole"/><div className="barrier-post"/><div className="road-car"><CarFront size={54} strokeWidth={1.3} /></div><span className="road-number">01</span></div><div className="lane-glow"/></div></section>
    <section className="interface-grid"><InterfaceCard to="/entrada" number="01" title="Terminal de entrada" desc="Ingreso de vehículos y validación de reservas." icon={<ArrowDownToLine />} color="green" /><InterfaceCard to="/salida" number="02" title="Terminal de salida" desc="Registro de egresos y gestión de reservas." icon={<ArrowUpFromLine />} color="blue" /><InterfaceCard to="/admin/login" number="03" title="Panel de control" desc="Ocupación, componentes y monitoreo en tiempo real." icon={<Gauge />} color="amber" /></section>
    <footer className="home-footer"><span>TFC <b>·</b> ESTACIONAMIENTO <b>·</b> SISTEMA ACADÉMICO</span><span className="simulation-indicator"><i /> SIMULACIÓN ACTIVA</span></footer>
  </main>
}

function Brand() { return <Link to="/" className="brand"><div className="brand-mark"><CircleParking size={21} /></div><span>TFC<span className="brand-dot">.</span><small>ESTACIONAMIENTO</small></span></Link> }

function InterfaceCard({ to, number, title, desc, icon, color }: { to: string; number: string; title: string; desc: string; icon: React.ReactNode; color: string }) {
  return <Link to={to} className={`interface-card ${color}`}><div className="card-top"><span className="card-number">{number} / 03</span><div className="card-icon">{icon}</div></div><div><h2>{title}</h2><p>{desc}</p></div><div className="card-enter">Ingresar <ArrowRight size={16} /></div></Link>
}

function Terminal({ direction }: { direction: Direction }) {
  const state = useParking()
  const [modal, setModal] = useState(false)
  const [vehicle, setVehicle] = useState<VehicleType | null>(null)
  const [token, setToken] = useState('')
  const [message, setMessage] = useState('')
  const [messageTone, setMessageTone] = useState<'success' | 'error' | 'neutral'>('error')
  const [retain, setRetain] = useState(true)
  const [terminalCredentialInput, setTerminalCredentialInput] = useState('')
  const [terminalLinkStatus, setTerminalLinkStatus] = useState<'checking' | 'linked' | 'unlinked'>(isSupabaseConfigured ? 'checking' : 'unlinked')
  const [activeTerminalOperation, setActiveTerminalOperation] = useState('')
  const [activeProgress, setActiveProgress] = useState<TerminalOperationProgress | null>(null)
  const [restoringOperation, setRestoringOperation] = useState(isSupabaseConfigured)
  const [requestPending, setRequestPending] = useState(false)
  const [lastOutcome, setLastOutcome] = useState<'confirmed' | 'cancelled' | 'failed' | null>(null)
  const launchLock = useRef(false)
  const navigate = useNavigate()
  const isEntry = direction === 'entry'
  const terminalLinked = terminalLinkStatus === 'linked'
  const op = isSupabaseConfigured ? undefined : state.operations[direction]
  const available = CAPACITY.regular - state.counts.regular - (state.operations.entry?.vehicle === 'regular' ? 1 : 0)
  useEffect(() => {
    if (!isSupabaseConfigured) { setTerminalLinkStatus('unlinked'); return }
    let current = true
    setTerminalLinkStatus('checking')
    void migrateLegacyTerminalCredential(direction, sessionStorage, terminalCredentialStorage).then(() => restoreTerminalCredential(direction, (lane, credential) => supabaseParking.getTerminalCredentialStatus(lane, credential), terminalCredentialStorage)).then((result) => {
      if (!current) return
      if (result.status === 'valid') setTerminalLinkStatus('linked')
      else if (result.status === 'blocked') {
        setTerminalLinkStatus('unlinked')
        setRestoringOperation(false)
        setMessageTone('neutral')
        setMessage('La validación de esta terminal está bloqueada temporalmente por intentos previos. La credencial se conserva; esperá un minuto y actualizá la página.')
      } else if (result.status === 'invalid' || result.status === 'revoked') {
        setTerminalLinkStatus('unlinked')
        setRestoringOperation(false)
        setMessageTone('error')
        setMessage(result.status === 'revoked' ? 'La credencial de esta terminal fue revocada. Se eliminó del navegador; volvé a vincularla desde administración.' : 'La credencial guardada no es válida para esta terminal. Se eliminó del navegador; volvé a vincularla desde administración.')
      } else { setTerminalLinkStatus('unlinked'); setRestoringOperation(false) }
    }).catch((error: Error) => {
      if (!current) return
      setTerminalLinkStatus('unlinked')
      setRestoringOperation(false)
      setMessageTone('error')
      setMessage(`No pudimos validar la credencial guardada. Revisá la conexión e intentá vincularla de nuevo. ${error.message}`)
    })
    return () => { current = false }
  }, [direction])
  useEffect(() => {
    if (!isSupabaseConfigured || !terminalLinked) return
    let current = true
    setRestoringOperation(true)
    void supabaseParking.getActiveTerminalOperation(direction).then(async (operation) => {
      if (!current || !operation) return
      const progress = await supabaseParking.getTerminalOperation(direction, operation.operation_id)
      if (!current) return
      setActiveTerminalOperation(progress.operation_id)
      if (progress.operation_status === 'confirmed' || progress.operation_status === 'cancelled' || progress.operation_status === 'failed') {
        setLastOutcome(progress.operation_status)
        setActiveProgress(null)
        setActiveTerminalOperation('')
      } else setActiveProgress(progress)
    }).catch((error: Error) => {
      if (current) {
        setMessageTone('error')
        setMessage(`No pudimos recuperar el estado de la operación. ${error.message}`)
      }
    }).finally(() => { if (current) setRestoringOperation(false) })
    return () => { current = false }
  }, [direction, terminalLinked])
  useEffect(() => {
    if (!activeTerminalOperation) return
    const reconcile = () => {
      void supabaseParking.getTerminalOperation(direction, activeTerminalOperation).then((operation) => {
        if (operation.operation_status === 'confirmed' || operation.operation_status === 'cancelled' || operation.operation_status === 'failed') {
          setLastOutcome(operation.operation_status)
          setActiveProgress(null)
          setActiveTerminalOperation('')
          setMessage('')
        } else setActiveProgress(operation)
      }).catch((error: Error) => {
        setMessageTone('error')
        setMessage(`No pudimos actualizar el estado desde Supabase. ${error.message}`)
      })
    }
    void reconcile()
    const timer = window.setInterval(reconcile, 1500)
    return () => window.clearInterval(timer)
  }, [activeTerminalOperation, direction])
  useEffect(() => {
    if (!modal) return
    function handleKey(event: KeyboardEvent) { if (event.key === 'Escape') setModal(false) }
    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [modal])

  function begin(type: VehicleType) {
    setMessage('')
    setMessageTone('error')
    setLastOutcome(null)
    if (type === 'reserved') { setVehicle(type); setToken(''); setRetain(true); setModal(true); return }
    launch(type)
  }
  async function launch(type: VehicleType, reservation = undefined as ReturnType<typeof parkingStore.findReservation>, shouldRetain = true) {
    if (launchLock.current) return
    launchLock.current = true
    setRequestPending(true)
    try {
      if (isSupabaseConfigured) {
        const id = await supabaseParking.startTerminal(direction, type, reservation?.token ?? token, shouldRetain ? 'retain' : 'finish')
        setActiveTerminalOperation(id)
        setActiveProgress({ operation_id: id, direction, vehicle_type: type, operation_status: 'pending', source: state.mode === 'simulation' ? 'simulation' : 'device', command_status: null, command_result: null })
      } else await parkingStore.start(direction, type, reservation, shouldRetain ? 'retain' : 'finish')
      setModal(false); setVehicle(null); setToken('')
    } catch (error) {
      setMessageTone('error')
      setMessage(error instanceof Error ? error.message : 'No pudimos autorizar la operación.')
    }
    finally { launchLock.current = false; setRequestPending(false) }
  }
  function submitToken() {
    if (isSupabaseConfigured) { void launch('reserved', undefined, retain); return }
    const found = parkingStore.findReservation(token)
    if (!found) { setMessageTone('error'); setMessage('No encontramos una reserva con ese token. Revisá los seis dígitos e intentá de nuevo.'); return }
    if (!isEntry && found.state === 'estacionado') { setVehicle('reserved'); setMessage(''); return }
    launch('reserved', found, retain)
  }
  const busy = Boolean(op || requestPending || restoringOperation || activeProgress || activeTerminalOperation)
  async function saveTerminalSecret() {
    setMessage('')
    setMessageTone('neutral')
    setTerminalLinkStatus('checking')
    try {
      await validateAndStoreTerminalCredential(direction, terminalCredentialInput, (lane, credential) => supabaseParking.validateTerminalCredential(lane, credential), terminalCredentialStorage)
      setTerminalCredentialInput('')
      setTerminalLinkStatus('linked')
      setMessage('')
      setMessageTone('neutral')
    } catch (error) {
      setTerminalLinkStatus('unlinked')
      setMessageTone('error')
      setMessage(error instanceof Error ? error.message : 'No pudimos validar la credencial de esta terminal.')
    }
  }
  const controllerOnline = state.mode === 'simulation' ? state.connected : physicalControllerOnline(state, Date.now())
  const closeTokenScreen = () => { setModal(false); setVehicle(null); setToken(''); setMessage('') }
  function addTokenDigit(digit: string) { setToken((current) => current.length < 6 ? current + digit : current) }
  function submitTokenScreen() {
    if (requestPending || token.length !== 6) return
    if (vehicle === 'reserved' && !isEntry) { void launch('reserved', parkingStore.findReservation(token), retain); return }
    submitToken()
  }
  const unavailableRegular = isEntry ? available <= 0 : state.counts.regular <= 0
  const unavailableReserved = !isEntry && state.counts.reserved <= 0
  const unavailableTemporary = !isEntry && state.counts.temporary <= 0
  const choices = [
    { type: 'regular' as const, icon: <CarFront/>, unavailable: unavailableRegular, note: unavailableRegular ? (isEntry ? 'Sin lugares disponibles' : 'No hay vehículos para retirar') : isEntry ? 'Ingreso regular' : 'Retiro regular' },
    { type: 'temporary' as const, icon: <Clock3/>, unavailable: unavailableTemporary, note: unavailableTemporary ? 'No hay vehículos para retirar' : isEntry ? 'Visita temporal' : 'Retiro temporal' },
    { type: 'reserved' as const, icon: <Ticket/>, unavailable: unavailableReserved, note: unavailableReserved ? 'No hay reservas estacionadas' : isEntry ? 'Con token de reserva' : 'Retiro con token' },
  ]
  return <main className={`terminal-screen ${modal ? 'token-screen' : ''}`}>
    <header className="terminal-header">
      <div className="terminal-brand"><b>TFC Estacionamiento</b><small>Terminal de {isEntry ? 'entrada' : 'salida'}</small></div>
      <div className="terminal-status"><span className={`connection-status ${controllerOnline ? 'online' : 'offline'}`}><i/>{controllerOnline ? 'Disponible' : 'Sin conexión'}</span><button className="icon-button" aria-label="Volver al inicio" onClick={() => navigate('/')}><X size={19}/></button></div>
    </header>
    <div className={`terminal-body ${modal ? 'token-body' : 'home-terminal-body'}`}>
      {busy ? <section className="terminal-wait" aria-live="polite">
        <div className="terminal-intro"><p className="eyebrow">{restoringOperation ? 'INICIO' : isEntry ? 'INGRESO' : 'SALIDA'}</p><h1>{restoringOperation ? 'Verificando…' : requestPending ? 'Procesando…' : 'En curso…'}</h1></div>
        {activeProgress ? <OperationProgressPanel progress={activeProgress} mode={state.mode}/> : op ? <OperationPanel direction={direction}/> : <OperationLoadingPanel restoring={restoringOperation}/>}
        {message && <div className={`inline-alert ${messageTone}`} role="alert"><TriangleAlert size={18}/>{message}</div>}
      </section> : modal ? <section className="token-entry" aria-labelledby="token-title">
        <div className="token-heading"><button className="back-button" onClick={closeTokenScreen}><ArrowLeft size={18}/> Volver</button><div><p className="eyebrow">ACCESO RESERVADO</p><h1 id="token-title">Ingresá el token</h1></div></div>
        <label className="token-input-label" htmlFor="reservation-token">Código de seis dígitos
          <input id="reservation-token" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={token} onChange={(event) => setToken(normalizeReservationTokenInput(event.target.value))} onPaste={(event) => { event.preventDefault(); setToken(normalizeReservationTokenInput(event.clipboardData.getData('text'))) }} onKeyDown={(event) => { if (event.key === 'Enter') submitTokenScreen() }} placeholder="000000" aria-describedby="reservation-token-help"/>
          <small id="reservation-token-help">Escribilo o pegalo completo. Se conservan los ceros iniciales.</small>
        </label>
        <div className="touch-keypad" aria-label="Teclado numérico">
          {['1','2','3','4','5','6','7','8','9','clear','0','back'].map((key) => <button key={key} type="button" aria-label={key === 'clear' ? 'Borrar todo' : key === 'back' ? 'Borrar último dígito' : `Ingresar ${key}`} onClick={() => key === 'clear' ? setToken('') : key === 'back' ? setToken((current) => current.slice(0,-1)) : addTokenDigit(key)}>{key === 'clear' ? 'Borrar' : key === 'back' ? '⌫' : key}</button>)}
        </div>
        {!isEntry && <fieldset className="retain-choice"><legend>Al salir, la reserva</legend><label><input type="radio" name="reservation-action" checked={retain} onChange={() => setRetain(true)}/> Se conserva</label><label><input type="radio" name="reservation-action" checked={!retain} onChange={() => setRetain(false)}/> Se libera</label></fieldset>}
        {message && <div className={`inline-alert ${messageTone}`} role={messageTone === 'error' ? 'alert' : 'status'}><TriangleAlert size={18}/>{message}</div>}
        <button className="primary-button validate-token" disabled={token.length !== 6 || requestPending} onClick={submitTokenScreen}>{requestPending ? 'Validando…' : 'Validar token'}<ArrowRight size={18}/></button>
      </section> : <section className="choice-area">
        <div className="terminal-intro"><p className="eyebrow">{isEntry ? 'INGRESO' : 'SALIDA'}</p><h1>Elegí una modalidad</h1><p>{isEntry ? 'Seleccioná cómo vas a ingresar.' : 'Seleccioná el tipo de vehículo que va a salir.'}</p></div>
        {isSupabaseConfigured && terminalLinkStatus === 'checking' && <div className="linking-hint" role="status">Verificando acceso…</div>}
        {isSupabaseConfigured && !terminalLinked && terminalLinkStatus !== 'checking' && <div className="inline-alert neutral credential-prompt"><LockKeyhole size={16}/><label>Vinculá esta terminal<input type="password" autoComplete="off" value={terminalCredentialInput} onChange={(event) => setTerminalCredentialInput(event.target.value)} placeholder="Credencial de acceso"/></label><button className="secondary-button" disabled={terminalCredentialInput.trim().length < 40} onClick={() => void saveTerminalSecret()}>Validar</button></div>}
        {lastOutcome && <div className={`terminal-outcome ${lastOutcome}`} role={lastOutcome === 'confirmed' ? 'status' : 'alert'}>{lastOutcome === 'confirmed' ? 'Paso confirmado.' : lastOutcome === 'cancelled' ? 'Operación cancelada.' : 'No se pudo completar la operación.'}</div>}
        {!isEntry && state.counts.regular === 0 && state.counts.temporary === 0 && state.counts.reserved === 0 && <p className="terminal-empty-note">No hay vehículos para retirar.</p>}
        <div className="availability-line"><span><span className="signal-dot"/> {isEntry ? 'Regulares disponibles' : 'Vehículos regulares'}</span><strong>{isEntry ? Math.max(available,0) : state.counts.regular}<small> / 7</small></strong></div>
        <div className="choice-grid">{choices.map(({type,icon,unavailable,note}) => <button key={type} type="button" disabled={unavailable || (isSupabaseConfigured && !terminalLinked)} className={`choice-card ${type}`} onClick={() => begin(type)}><span className="choice-icon">{icon}</span><span className="choice-title">{vehicleLabels[type]}</span><small>{note}</small></button>)}</div>
        {message && <div className={`inline-alert ${messageTone}`} role={messageTone === 'error' ? 'alert' : 'status'}><TriangleAlert size={18}/>{message}</div>}
      </section>}
    </div>
    <footer className="terminal-footer"><span>ESTACIONAMIENTO · {isEntry ? 'ENTRADA' : 'SALIDA'}</span><span>{state.mode === 'simulation' ? 'Modo demostración' : 'Atención automatizada'}</span></footer>
  </main>
}

function OperationPanel({ direction }: { direction: Direction }) {
  const state = useParking()
  const op = state.operations[direction]
  if (!op) return null
  return <section className="operation-card" aria-live="polite"><div className="operation-animation"><div className="pulse-ring"><CarFront size={42} /></div></div><span className="eyebrow">SIMULACIÓN LOCAL</span><h2>{op.status === 'detected' ? 'Paso en curso' : 'Esperando el paso simulado'}</h2><p>{vehicleLabels[op.vehicle]} · {direction === 'entry' ? 'Ingreso' : 'Salida'}</p><div className="operation-track"><span className="done"><Check /></span><i /><span className={op.status === 'detected' ? 'done' : ''}><CarFront /></span><i /><span><DoorOpen /></span></div><small>Esta vista no representa el estado de una barrera física.</small></section>
}

function OperationLoadingPanel({ restoring }: { restoring: boolean }) {
  return <section className={`operation-card ${restoring ? 'reconciling' : ''}`} aria-live="polite" aria-busy="true"><div className="operation-animation"><div className="pulse-ring"><Activity size={38} /></div></div><span className="eyebrow">{restoring ? 'VERIFICACIÓN DE ESTADO' : 'SOLICITUD ENVIADA'}</span><h2>{restoring ? 'Consultando operación activa' : 'Enviando orden al controlador'}</h2><p>{restoring ? 'Esperá la respuesta actual del backend antes de mostrar las opciones de acceso.' : 'Esperá la respuesta de Supabase antes de volver a seleccionar una modalidad.'}</p></section>
}

function OperationProgressPanel({ progress, mode }: { progress: TerminalOperationProgress; mode: 'simulation' | 'hardware' }) {
  const physicalController = progress.source === 'device' || (progress.source === undefined && mode === 'hardware')
  const barrierActuated = progress.command_result?.barrier_actuated === true
  let eyebrow = physicalController ? 'CONTROLADOR FÍSICO · ESP8266' : 'CONTROLADOR SIMULADO'
  let title = 'Esperando confirmación de apertura'
  let detail = 'La orden fue enviada. Todavía no se confirmó su ejecución.'
  let sensorDetected = false

  if (progress.operation_status === 'detected') {
    eyebrow = 'VEHÍCULO DETECTADO'
    title = 'Esperando paso completo'
    detail = 'El sensor debe quedar libre de forma estable durante 500 ms para finalizar.'
    sensorDetected = true
  } else if (progress.command_status === 'failed') {
    eyebrow = 'APERTURA NO CONFIRMADA'
    title = 'El controlador informó un error'
    detail = 'La operación sigue reservada. Pedí a administración que la cancele antes de iniciar otra.'
  } else if (progress.command_status === 'cancelled') {
    eyebrow = 'ORDEN CANCELADA'
    title = 'La apertura fue cancelada'
    detail = 'Actualizando el estado de la terminal…'
  } else if (!physicalController && !progress.command_status) {
    eyebrow = 'CONTROLADOR SIMULADO'
    title = 'Esperando a simulated-esp8266'
    detail = 'La operación continúa pendiente hasta completar la secuencia simulada del sensor.'
  } else if (progress.command_status === 'received') {
    title = 'Orden recibida por la ESP8266'
    detail = 'Esperando que confirme la ejecución de open_gate.'
  } else if (progress.command_status === 'running') {
    title = 'La ESP8266 está ejecutando la orden'
    detail = 'La apertura todavía no está confirmada.'
  } else if (progress.command_status === 'confirmed' && barrierActuated) {
    eyebrow = 'APERTURA FÍSICA CONFIRMADA'
    title = 'Barrera abierta. Puede avanzar.'
    detail = 'Esperando que el vehículo atraviese y libere el sensor infrarrojo.'
  } else if (progress.command_status === 'confirmed') {
    eyebrow = 'PRUEBA DEL LED CONFIRMADA'
    title = 'La ESP8266 confirmó la señal'
    detail = 'El resultado informa que no accionó una barrera física. La operación espera el paso y el sensor infrarrojo.'
  }

  return <section className={`operation-card progress-card ${progress.command_status === 'failed' ? 'failed' : progress.operation_status === 'detected' ? 'processing' : ''}`} aria-live="polite"><div className="operation-animation"><div className="pulse-ring"><CarFront size={42} /></div></div><span className="eyebrow">{eyebrow}</span><h2>{title}</h2><p>{detail}</p>{progress.direction === 'entry' && progress.vehicle_type === 'reserved' && <p className="reserved-guidance" role="status">Estacioná en una de las plazas iluminadas de verde.</p>}<div className="operation-track"><span className="done"><Check /></span><i className={progress.command_status === 'confirmed' ? 'done' : ''}/><span className={progress.command_status === 'confirmed' ? 'done' : ''}><DoorOpen /></span><i className={sensorDetected ? 'active' : ''}/><span className={sensorDetected ? 'active' : ''}><CarFront /></span></div><small>{vehicleLabels[progress.vehicle_type]} · {progress.direction === 'entry' ? 'Ingreso' : 'Salida'} · Los contadores se actualizan al completar el sensor.</small></section>
}

function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [message, setMessage] = useState('')
  const navigate = useNavigate()
  async function login(event: React.FormEvent) {
    event.preventDefault()
    if (!supabase) { setMessage('Configurá Supabase en .env.local para autenticar administradores. La simulación demo sólo está habilitada en desarrollo.'); return }
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setMessage('No se pudo iniciar sesión. Revisá las credenciales.')
    else {
      const { data: isAdmin, error: roleError } = await supabase.rpc('is_current_admin')
      if (roleError || isAdmin !== true) { await supabase.auth.signOut(); setMessage('La cuenta no tiene permisos de administración.') }
      else navigate('/admin')
    }
  }
  return <main className="login-screen"><div className="login-aside"><Brand /><div className="login-art"><div className="login-orbit orbit-one"/><div className="login-orbit orbit-two"/><div className="login-icon"><ShieldCheck size={54} /></div><span className="art-label label-a">CONTROL DE ACCESO</span><span className="art-label label-b">SISTEMA EN LÍNEA</span></div><p className="login-aside-footer">MONITOREO CENTRALIZADO <b>·</b> 01 / 03</p></div><div className="login-form-side"><Link to="/" className="back-link"><ArrowLeft size={16} /> Volver al inicio</Link><form className="login-form" onSubmit={login}><div className="choice-icon amber"><LockKeyhole /></div><p className="eyebrow">ÁREA RESTRINGIDA</p><h1>Hola de nuevo.</h1><p className="muted">Ingresá con tu cuenta de administrador.</p><label>Correo electrónico<input autoComplete="username" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="nombre@correo.com" /></label><label>Contraseña<input autoComplete="current-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} required placeholder="••••••••" /></label>{message && <div className="inline-alert">{message}</div>}<button className="primary-button">Iniciar sesión <ArrowRight size={16} /></button>{import.meta.env.DEV && !isSupabaseConfigured && <button type="button" className="demo-button" onClick={() => navigate('/admin?demo=1')}>Entrar a la simulación local de desarrollo</button>}<small><LockKeyhole size={13} /> Acceso protegido por Supabase Auth. No hay registro público.</small></form></div></main>
}

function Admin() {
  const state = useParking()
  const [clock, setClock] = useState(Date.now())
  const navigate = useNavigate()
  const demo = import.meta.env.DEV && new URLSearchParams(location.search).get('demo') === '1'
  const [authenticated, setAuthenticated] = useState(Boolean(demo))
  const [tab, setTab] = useState('Resumen')
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const [date, setDate] = useState(localDate())
  const [notice, setNotice] = useState('')
  const [reservationTokens, setReservationTokens] = useState<Record<string, string | null>>({})
  const [reservationTokensLoading, setReservationTokensLoading] = useState(false)
  const [authChecking, setAuthChecking] = useState(Boolean(supabase))
  const autoSimulatedOperations = useRef(new Set<string>())
  useEffect(() => {
    const timer = window.setInterval(() => setClock(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])
  useEffect(() => {
    if (!supabase) return
    void (async () => {
      const { data } = await supabase.auth.getSession()
      if (!data.session) { setAuthenticated(false); setAuthChecking(false); return }
      const { data: isAdmin, error } = await supabase.rpc('is_current_admin')
      setAuthenticated(!error && isAdmin === true)
      setAuthChecking(false)
    })()
  }, [])
  useEffect(() => {
    let current = true
    setReservationTokens({})
    if (!authenticated || tab !== 'Reservas' || !supabase) return () => { current = false }
    setReservationTokensLoading(true)
    void supabaseParking.getReservationTokens(date).then((items) => {
      if (!current) return
      setReservationTokens(Object.fromEntries(items.map((item) => [item.id, item.token])))
    }).catch((error: Error) => {
      if (current) setNotice(`No pudimos recuperar los tokens de esta fecha. ${error.message}`)
    }).finally(() => { if (current) setReservationTokensLoading(false) })
    return () => { current = false }
  }, [authenticated, tab, date])
  useEffect(() => {
    if (!authenticated) setReservationTokens({})
  }, [authenticated])
  useEffect(() => {
    if (!authenticated || state.mode !== 'simulation' || !state.connected || !state.automatic) return
    for (const operation of Object.values(state.operations)) {
      if (!operation || operation.source !== 'simulation' || operation.requestOrigin !== 'terminal' || autoSimulatedOperations.current.has(operation.id)) continue
      autoSimulatedOperations.current.add(operation.id)
      void supabaseParking.runAutomaticTerminalSimulation(operation.id).catch((error: Error) => setNotice(`Falló la secuencia del controlador simulado: ${error.message}`))
    }
  }, [authenticated, state.automatic, state.connected, state.mode, state.operations])
  if (authChecking) return <div className="auth-loading">Verificando acceso…</div>
  if (!authenticated) return <Navigate to="/admin/login" replace />
  const total = state.counts.regular + state.counts.reserved + state.counts.temporary
  const assigned = state.reservations.filter((r) => r.date === date && !['finalizada','revocada','vencida'].includes(r.state)).length
  async function signOut() { if (supabase) await supabase.auth.signOut(); setReservationTokens({}); setAuthenticated(false); navigate('/admin/login') }
  async function copyReservationToken(token: string) {
    try { await navigator.clipboard.writeText(token); setNotice('Token copiado al portapapeles.') }
    catch { setNotice('El navegador no permitió copiarlo. Seleccioná el token y copialo manualmente.') }
  }
  async function createReservation() {
    try {
      const item = await parkingStore.createReservation(date)
      setReservationTokens((current) => ({ ...current, [item.id]: item.token }))
      await copyReservationToken(item.token)
    } catch (error) { setNotice(error instanceof Error ? error.message : 'No se pudo crear la reserva.') }
  }
  async function regenerateReservationToken(id: string) {
    try {
      const item = await supabaseParking.regenerateReservationToken(id)
      setReservationTokens((current) => ({ ...current, [id]: item.token }))
      setNotice('Token regenerado. El anterior dejó de ser válido.')
    } catch (error) { setNotice(error instanceof Error ? error.message : 'No se pudo regenerar el token.') }
  }
  function startManual(direction: Direction, vehicle: VehicleType) { parkingStore.start(direction, vehicle).catch((e: Error) => setNotice(e.message)) }
  async function resetDemo() { if (!confirm('¿Restablecer la simulación? Se pondrán los contadores en cero y se cancelarán las reservas activas.')) return; try { await parkingStore.reset(); setNotice('Simulación restablecida. El historial se conserva.') } catch (error) { setNotice(error instanceof Error ? error.message : 'No se pudo restablecer la simulación.') } }
  return <main className="admin-shell"><aside className="sidebar"><div className="sidebar-heading"><Brand /><button className="mobile-nav-toggle" aria-label={mobileNavOpen ? 'Cerrar navegación' : 'Abrir navegación'} aria-expanded={mobileNavOpen} aria-controls="admin-navigation" onClick={() => setMobileNavOpen((open) => !open)}>{mobileNavOpen ? <X size={20}/> : <Menu size={20}/>}</button></div><div className="sidebar-mode"><span><i /> {state.mode === 'simulation' ? 'SIMULACIÓN' : 'HARDWARE'}</span><small>{state.mode === 'simulation' ? 'Controlador simulado separado' : 'Control físico seleccionado'}</small></div><nav id="admin-navigation" className={mobileNavOpen ? 'open' : ''}>{[['Resumen', Gauge], ['Reservas', Ticket], ['Componentes', Settings2], ['Historial', Activity], ...(isLocalSupabase ? [['Mantenimiento', RotateCcw] as [string, typeof RotateCcw]] : [])].map(([name, Icon]) => <button key={name as string} className={tab === name ? 'active' : ''} onClick={() => { setTab(name as string); setMobileNavOpen(false) }}>{<Icon size={18} />}{name as string}</button>)}</nav><div className="sidebar-bottom"><div className="user-mini"><span className="avatar">NA</span><span><b>Administrador</b><small>{demo ? 'Sesión local de desarrollo' : 'Cuenta autenticada'}</small></span></div><button className="logout-button" onClick={signOut}><LogOut size={16} /> Cerrar sesión</button></div></aside>
    <section className="admin-content"><header className="admin-topbar"><div><span className="breadcrumb">NORTE <b>/</b> {tab.toUpperCase()}</span><h1>{tab === 'Resumen' ? 'Panel de control' : tab}</h1></div><div className="topbar-right"><span className="status-chip"><i /> {state.mode === 'simulation' ? 'Modo simulación' : 'Modo hardware'}</span><span className="date-label">{new Intl.DateTimeFormat('es-AR', { dateStyle: 'medium' }).format(new Date())}</span></div></header>
    <div className="admin-main">{notice && <div className="notice-banner"><BadgeCheck size={17} /> {notice}<button onClick={() => setNotice('')}><X size={16} /></button></div>}
    {tab === 'Resumen' && <><div className="welcome-row"><div><p className="muted">ESTADO GENERAL DEL ESTACIONAMIENTO</p><h2>Todo bajo control<span className="green-text">.</span></h2></div><div className="connection-pill"><span className="connection-icon">{state.mode === 'simulation' ? (state.connected ? <Wifi/> : <WifiOff/>) : (physicalControllerOnline(state, clock) ? <Wifi/> : <WifiOff/>)}</span><span><b>{state.mode === 'simulation' ? (state.connected ? 'Controlador simulado activo' : 'Controlador simulado desconectado') : (physicalControllerOnline(state, clock) ? 'ESP8266 física conectada' : 'ESP8266 física sin comunicación')}</b><small>{state.mode === 'simulation' ? 'Identidad: simulated-esp8266' : 'Identidad: esp8266-main · heartbeat requerido'}</small></span></div></div>
    <div className="metrics-grid"><Metric label="Vehículos presentes" value={total} suffix="unidades" icon={<CarFront />} tone="blue"/><Metric label="Plazas ocupadas" value={state.counts.regular + state.counts.reserved} suffix="de 10" icon={<ParkingCircle />} tone="green"/><Metric label="Disponibilidad regular" value={CAPACITY.regular - state.counts.regular} suffix="de 7 libres" icon={<CircleParking />} tone="amber"/><Metric label="Visitas temporales" value={state.counts.temporary} suffix="en el predio" icon={<Clock3 />} tone="purple"/></div>
    <div className="dashboard-grid"><section className="panel occupancy-panel"><PanelTitle title="Ocupación actual" subtitle="Vista agregada · sin asignación individual"/><div className="occupancy-summary"><div><strong>{state.counts.regular}<small> / 7</small></strong><span>Regulares</span></div><div><strong>{state.counts.reserved}<small> / 3</small></strong><span>Reservadas</span></div><div><strong>{state.counts.temporary}</strong><span>Temporales</span></div></div><div className="space-map"><div className="map-label">PLAZAS REGULARES</div><div className="slot-row">{Array.from({ length: 7 }, (_, i) => <div key={i} className={`parking-slot ${i < state.counts.regular ? 'occupied' : ''}`}><CarFront size={18}/><small>R{i + 1}</small></div>)}</div><div className="map-label reserved-label">PLAZAS RESERVADAS</div><div className="slot-row">{Array.from({ length: 3 }, (_, i) => <div key={i} className={`parking-slot reserved-slot ${i < state.counts.reserved ? 'occupied' : ''}`}><CarFront size={18}/><small>P{i + 1}</small></div>)}</div></div><div className="legend"><span><i className="legend-free"/> Disponible</span><span><i className="legend-used"/> Ocupación agregada</span></div></section>
    <section className="panel hardware-panel"><PanelTitle title="Estado del sistema" subtitle={state.mode === 'simulation' ? 'Controlador simulated-esp8266' : 'Controlador físico esp8266-main'}/><StatusLine icon={<DoorOpen />} label="Barrera de entrada" status={gateStatus(state, 'entry')} active={state.mode === 'simulation' ? Boolean(state.operations.entry) : state.sensors.entry}/><StatusLine icon={<DoorOpen />} label="Barrera de salida" status={gateStatus(state, 'exit')} active={state.mode === 'simulation' ? Boolean(state.operations.exit) : state.sensors.exit}/><StatusLine icon={<Activity />} label="Sensor de entrada" status={sensorStatus(state, 'entry', clock)} active={sensorStatus(state, 'entry', clock) === 'Detectando'}/><StatusLine icon={<Activity />} label="Sensor de salida" status={sensorStatus(state, 'exit', clock)} active={sensorStatus(state, 'exit', clock) === 'Detectando'}/><StatusLine icon={state.mode === 'hardware' ? <Sun/> : state.night ? <Moon /> : <Sun />} label="Iluminación" status={lightingStatus(state, clock)} active={state.mode === 'hardware' ? state.lightingTelemetry?.whiteLightsOn === true : state.night}/><StatusLine icon={<span className="traffic-light"><i/><i className={CAPACITY.regular > state.counts.regular ? 'on' : ''}/></span>} label="Semáforo regular" status={CAPACITY.regular > state.counts.regular ? 'Verde · hay disponibilidad' : 'Rojo · completo'} active={CAPACITY.regular > state.counts.regular}/><button className="text-button" onClick={() => setTab('Componentes')}>Controlar componentes <ArrowRight size={15}/></button></section></div>
    <section className="panel reservations-panel"><PanelTitle title="Reservas para la fecha" subtitle={`${assigned} de 3 cupos asignados`} action={<Link to="#reservas" onClick={(e) => {e.preventDefault();setTab('Reservas')}} className="text-button">Ver reservas <ArrowRight size={15}/></Link>}/><div className="reservation-preview">{state.reservations.filter((r) => r.date === date).slice(0, 3).map((r) => <div key={r.id}><Ticket size={17}/><b>••• {r.tokenSuffix ?? r.token.slice(-3)}</b><span>{r.state}</span></div>)}{assigned === 0 && <p className="muted">No hay reservas asignadas para hoy.</p>}</div></section>
    </>}
    {tab === 'Reservas' && <section className="panel full-panel"><PanelTitle title="Gestión de reservas" subtitle="Token de seis dígitos · vigencia por fecha"/><div className="reservation-toolbar"><label>Fecha de reserva<input type="date" value={date} min={localDate()} onChange={(e) => setDate(e.target.value)}/></label><button className="primary-button compact" disabled={assigned >= 3} onClick={() => void createReservation()}><Plus size={16}/> Generar token</button><div className="quota"><b>{assigned} / 3</b><small>cupos asignados</small></div></div><div className="reservation-list">{state.reservations.filter((r) => r.date === date).map((r) => { const tokenEligible = ['disponible', 'conservada'].includes(r.state) && r.date >= localDate(); const token = reservationTokens[r.id] ?? ''; const tokenUnavailable = Object.hasOwn(reservationTokens, r.id) && reservationTokens[r.id] === null; return <ReservationRow key={r.id} reservation={{ ...r, token }} tokenEligible={tokenEligible} tokenUnavailable={tokenUnavailable} tokenLoading={reservationTokensLoading && !Object.hasOwn(reservationTokens, r.id)} onCopy={() => { if (tokenEligible && token) void copyReservationToken(token) }} onRegenerate={() => void regenerateReservationToken(r.id)} onRevoke={() => { void supabaseParking.revokeReservation(r.id).then(() => setNotice('Reserva revocada.')).catch((error: Error) => setNotice(error.message)) }}/> })}{!state.reservations.some((r) => r.date === date) && <Empty icon={<Ticket/>} title="Todavía no hay reservas" text="Generá un token para asignar un cupo reservado a esta fecha."/>}</div><p className="notice-text"><TriangleAlert size={15}/> Los tokens se recuperan por una RPC de administrador y se mantienen solo en memoria mientras dura la sesión.</p></section>}
    {tab === 'Componentes' && <div className="component-layout"><section className="panel full-panel"><PanelTitle title="Controladores" subtitle="El simulador y la ESP8266 física tienen estados y credenciales independientes"/><div className="simulation-banner"><div><b><Activity/> {state.mode === 'simulation' ? (state.connected ? 'Controlador simulado activo' : 'Controlador simulado desconectado') : 'Modo de hardware físico'}</b><p>{state.mode === 'simulation' ? 'Las señales se originan en simulated-esp8266 y nunca accionan hardware.' : 'Las operaciones requieren heartbeat reciente de esp8266-main.'}</p></div><label className="switch"><input type="checkbox" checked={state.mode === 'simulation'} onChange={(e) => parkingStore.set({ mode: e.target.checked ? 'simulation' : 'hardware' })}/><span/> <small>Modo simulación</small></label><label className="switch"><input type="checkbox" checked={state.automatic} onChange={(e) => parkingStore.set({ automatic: e.target.checked })}/><span/> <small>Secuencia automática</small></label></div><div className="control-section"><h3>Operaciones vehiculares</h3><p>Las terminales solicitan el paso; sólo el controlador activo puede reportar sensores.</p><div className="manual-grid">{(['entry','exit'] as Direction[]).map((direction) => <div key={direction} className="manual-lane"><b>{direction === 'entry' ? 'Barrera de entrada' : 'Barrera de salida'}</b><div className="manual-actions"><select aria-label="Modalidad" id={`type-${direction}`}><option value="regular">Regular</option><option value="reserved">Reservado</option><option value="temporary">Temporal</option></select><button className="secondary-button" disabled={Boolean(state.operations[direction]) || state.mode !== 'simulation' || !state.connected} onClick={() => startManual(direction, (document.getElementById(`type-${direction}`) as HTMLSelectElement).value as VehicleType)}><DoorOpen size={16}/> Autorizar</button></div>{state.operations[direction] && <div className="sensor-actions"><span>{state.sensors[direction] ? 'Vehículo detectado' : 'Esperando vehículo'} · {state.operations[direction]?.source === 'device' ? 'ESP8266 física' : 'simulated-esp8266'}</span>{state.operations[direction]?.source === 'simulation' && state.mode === 'simulation' && <><button onClick={() => void parkingStore.detect(direction)} disabled={state.sensors[direction]}>Simular detección</button><button onClick={() => void parkingStore.release(direction)} disabled={!state.sensors[direction]}>Liberar sensor</button></>}<button onClick={() => void parkingStore.cancel(direction)}>Cancelar operación</button></div>}</div>)}</div></div><div className="control-section"><h3>Condición ambiental</h3><div className="toggle-row"><span><Sun/> Iluminación del simulador</span><button className="secondary-button" disabled={state.mode !== 'simulation'} onClick={() => parkingStore.set({ night: !state.night })}>{state.night ? <Moon size={16}/> : <Sun size={16}/>} Simular {state.night ? 'día' : 'noche'}</button></div></div><div className="control-section"><h3>Acciones de prueba del simulador</h3><button className="secondary-button" onClick={() => setNotice('Buzzer simulado durante 300 ms.')}><AudioLines size={16}/> Probar buzzer · 300 ms</button><button className="secondary-button" disabled={state.mode !== 'simulation'} onClick={() => parkingStore.set({ connected: !state.connected })}>{state.connected ? <WifiOff size={16}/> : <Wifi size={16}/>} Simulated ESP8266: {state.connected ? 'desconectar' : 'conectar'}</button></div><ManualHardwareControls state={state} now={clock} onNotice={setNotice}/><TerminalProvisioning onNotice={setNotice}/><DeviceProvisioning onNotice={setNotice}/></section></div>}
    {tab === 'Mantenimiento' && isLocalSupabase && <LocalTestDataReset onNotice={setNotice}/>}
    {tab === 'Historial' && <section className="panel full-panel"><PanelTitle title="Historial de movimientos" subtitle="Origen registrado por Supabase para cada movimiento"/><div className="history-list">{state.history.map((movement) => <div key={movement.id}><span className={`history-icon ${movement.direction}`}><CarFront/></span><span><b>{movement.direction === 'entry' ? 'Ingreso' : 'Egreso'} {vehicleLabels[movement.vehicle].toLowerCase()}</b><small>{movement.simulated ? 'Controlador simulado · simulated-esp8266' : 'Controlador físico · esp8266-main'}</small></span><time>{new Intl.DateTimeFormat('es-AR',{hour:'2-digit',minute:'2-digit',day:'2-digit',month:'short'}).format(new Date(movement.at))}</time></div>)}{!state.history.length && <Empty icon={<Activity/>} title="Sin movimientos todavía" text="Los ingresos y egresos confirmados aparecen acá."/>}</div></section>}
    </div><footer className="admin-footer"><span>TFC <b>·</b> ESTACIONAMIENTO <b>·</b> PANEL DE ADMINISTRACIÓN</span>{!isSupabaseConfigured && demo && <button onClick={() => void resetDemo()}><RotateCcw size={14}/> Restablecer demostración</button>}</footer></section></main>
}

function LocalTestDataReset({ onNotice }: { onNotice: (message: string) => void }) {
  const [enabled, setEnabled] = useState(false)
  const [checked, setChecked] = useState(false)
  const [loading, setLoading] = useState(true)
  const [resetting, setResetting] = useState(false)
  useEffect(() => {
    let current = true
    void supabaseParking.isLocalTestDataResetEnabled().then((value) => {
      if (current) setEnabled(value)
    }).catch((error: Error) => {
      if (current) onNotice(`No se pudo comprobar la habilitación local del restablecimiento. ${error.message}`)
    }).finally(() => { if (current) setLoading(false) })
    return () => { current = false }
  }, [onNotice])

  async function reset() {
    if (!isLocalSupabase || !checked || !enabled || resetting) return
    if (!window.confirm('Esta acción es irreversible. Se eliminarán todas las reservas, tokens, operaciones, comandos e históricos operativos locales. ¿Confirmás el restablecimiento?')) return
    setResetting(true)
    try {
      const result = await supabaseParking.resetLocalTestData(true)
      setChecked(false)
      onNotice(`Restablecimiento local completado: ${result.reservations_deleted} reservas, ${result.operations_deleted} operaciones, ${result.commands_deleted} comandos y ${result.audit_events_deleted} eventos operativos eliminados. La configuración y las vinculaciones se conservaron.`)
    } catch (error) {
      onNotice(`No se pudo restablecer: ${localResetFailureMessage(error)}`)
    } finally { setResetting(false) }
  }

  return <section className="panel full-panel">
    <PanelTitle title="Restablecer datos de prueba" subtitle="Mantenimiento exclusivo de Supabase LOCAL"/>
    <div className="control-section">
      <p>Elimina reservas y tokens, operaciones vehiculares, comandos físicos e históricos operativos para preparar una nueva demostración. Conserva usuarios, terminales, credenciales, dispositivo, capacidad, modo y configuración.</p>
      <p className="notice-text"><TriangleAlert size={15}/> Acción irreversible. No se genera un respaldo. No acciona barreras ni envía comandos a la ESP8266.</p>
      {loading ? <p role="status">Verificando que la RPC esté habilitada en esta base local…</p> : !enabled ? <p className="inline-alert neutral">El backend mantiene deshabilitado el restablecimiento. Habilitalo únicamente en la base local.</p> : <>
        <label className="reset-confirmation"><input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)}/> Confirmo que el estacionamiento físico está vacío y que las dos barreras están cerradas.</label>
        <button className="secondary-button danger-button" disabled={!checked || resetting} onClick={() => void reset()}><RotateCcw size={16}/>{resetting ? 'Restableciendo…' : 'Restablecer datos de prueba'}</button>
      </>}
    </div>
  </section>
}

function ManualHardwareControls({ state, now, onNotice }: { state: ReturnType<typeof useParking>; now: number; onNotice: (message: string) => void }) {
  const [sending, setSending] = useState(false)
  const online = physicalControllerOnline(state, now)
  const operationActive = Boolean(state.operations.entry || state.operations.exit)
  const sensorFresh = Boolean(state.sensorUpdatedAt && now - Date.parse(state.sensorUpdatedAt) <= 30_000)
  const latest = state.latestManualCommand
  const statusLabel: Record<string, string> = { pending: 'Pendiente de ejecución', received: 'Recibido por la ESP8266', running: 'En ejecución', confirmed: 'Ejecutado y confirmado', failed: 'Falló', cancelled: 'Cancelado' }
  async function send(action: string, target: Direction | null = null) {
    setSending(true)
    try {
      const id = await supabaseParking.queueManualHardwareCommand(action, target)
      onNotice(`Comando enviado a la ESP8266. ID ${id.slice(0, 8)} · esperando confirmación física.`)
    } catch (error) { onNotice(error instanceof Error ? error.message : 'No se pudo enviar el comando.') }
    finally { setSending(false) }
  }
  const blocked = !online || !sensorFresh || operationActive || sending || Boolean(latest && ['pending', 'received', 'running'].includes(latest.status))
  return <div className="control-section">
    <h3>Controlar componentes físicos</h3>
    <p>{!online ? 'ESP8266 desconectada o heartbeat vencido. Los controles están bloqueados.' : !sensorFresh ? 'Sin telemetría reciente de ambos sensores. Actualizá el firmware LOCAL antes de habilitar mantenimiento.' : 'Comandos de mantenimiento enviados por Supabase a esp8266-main.'}{operationActive ? ' Hay una operación vehicular activa.' : ''}</p>
    {(['entry', 'exit'] as Direction[]).map((lane) => <div className="manual-lane" key={lane}>
      <b>Barrera de {lane === 'entry' ? 'entrada' : 'salida'}</b>
      <div className="manual-actions">
        <button className="secondary-button" disabled={blocked} onClick={() => void send('barrier_open', lane)}><DoorOpen size={15}/> Abrir</button>
        <button className="secondary-button" disabled={blocked || !sensorFresh || state.sensors[lane]} onClick={() => void send('barrier_close', lane)}><DoorOpen size={15}/> Cerrar</button>
      </div>
      <small>Sensor: {sensorStatus(state, lane, now)}{!sensorFresh ? ' · cierre bloqueado sin lectura reciente' : ''}</small>
    </div>)}
    <div className="manual-actions">
      <button className="secondary-button" disabled={blocked} onClick={() => void send('white_on')}><Sun size={15}/> Luces blancas encendidas</button>
      <button className="secondary-button" disabled={blocked} onClick={() => void send('white_off')}><Moon size={15}/> Luces blancas apagadas</button>
      <button className="secondary-button" disabled={blocked} onClick={() => void send('rgb_red')}>RGB rojo</button>
      <button className="secondary-button" disabled={blocked} onClick={() => void send('rgb_green')}>RGB verde</button>
      <button className="secondary-button" disabled={blocked} onClick={() => void send('rgb_off')}>Apagar RGB</button>
      <button className="secondary-button" disabled={blocked} onClick={() => void send('lighting_auto')}>Restaurar modo automático</button>
    </div>
    {latest && <p aria-live="polite">Último comando: {latest.action}{latest.target ? ` · ${latest.target}` : ''} · {statusLabel[latest.status] ?? latest.status}{latest.result?.reason ? ` · ${String(latest.result.reason)}` : ''}</p>}
    <small>El controlador confirma el resultado. El backend impide comandos con operaciones activas y cierres con sensores ocupados.</small>
  </div>
}

function TerminalProvisioning({ onNotice }: { onNotice: (message: string) => void }) {
  const [lane, setLane] = useState<Direction>('entry')
  const [secret, setSecret] = useState('')
  const [loading, setLoading] = useState(false)
  async function provision() {
    if (!supabase) { onNotice('Configurá Supabase para aprovisionar una terminal.'); return }
    setLoading(true)
    const terminalId = `terminal-${lane}`
    const { data, error } = await supabase.rpc('provision_terminal', { p_terminal_id: terminalId, p_lane: lane }).single()
    setLoading(false)
    if (error) { onNotice(`No se pudo aprovisionar: ${error.message}`); return }
    setSecret((data as { terminal_secret: string }).terminal_secret)
    onNotice(`Credencial nueva para ${terminalId}. Se muestra una sola vez; copiala y pegala en esa terminal.`)
  }
  return <div className="control-section"><h3>Vincular terminal</h3><p>Generá una credencial aleatoria para la interfaz de entrada o salida.</p><div className="manual-actions"><select aria-label="Terminal" value={lane} onChange={(event) => { setLane(event.target.value as Direction); setSecret('') }}><option value="entry">Entrada</option><option value="exit">Salida</option></select><button className="secondary-button" disabled={loading || !isSupabaseConfigured} onClick={() => void provision()}><LockKeyhole size={16}/>{loading ? 'Generando…' : 'Aprovisionar credencial'}</button></div>{secret && <label>Credencial · copiar ahora<input type="text" readOnly value={secret} onFocus={(event) => event.currentTarget.select()}/><button className="secondary-button" onClick={() => { void navigator.clipboard.writeText(secret); onNotice('Credencial copiada. Pegala en la terminal correspondiente.') }}><Copy size={15}/> Copiar credencial</button></label>}<small>La base guarda sólo SHA-256 de esta credencial. Si se pierde, aprovisioná una nueva para revocar la anterior.</small></div>
}

function DeviceProvisioning({ onNotice }: { onNotice: (message: string) => void }) {
  const [secret, setSecret] = useState('')
  async function provision() {
    if (!supabase) { onNotice('Configurá Supabase para preparar la credencial de la placa.'); return }
    const { data, error } = await supabase.rpc('provision_device', { p_device_id: 'esp8266-main' }).single()
    if (error) { onNotice(`No se pudo aprovisionar el ESP8266: ${error.message}`); return }
    setSecret((data as { device_secret: string }).device_secret)
    onNotice('Credencial nueva del ESP8266. Copiala en un lugar seguro; se muestra una sola vez.')
  }
  return <div className="control-section"><h3>Preparar ESP8266</h3><p>Generá una credencial independiente para heartbeat, comandos y eventos del dispositivo. No la compartas con las terminales.</p><button className="secondary-button" disabled={!isSupabaseConfigured} onClick={() => void provision()}><ShieldCheck size={16}/> Generar credencial del controlador</button>{secret && <label>Credencial del ESP8266 · copiar ahora<input type="text" readOnly value={secret} onFocus={(event) => event.currentTarget.select()}/><button className="secondary-button" onClick={() => { void navigator.clipboard.writeText(secret); onNotice('Credencial copiada. La placa debe usarla desde su configuración segura.') }}><Copy size={15}/> Copiar credencial</button></label>}</div>
}

function Metric({ label, value, suffix, icon, tone }: { label: string; value: number; suffix: string; icon: React.ReactNode; tone: string }) { return <article className="metric-card"><div className={`metric-icon ${tone}`}>{icon}</div><span>{label}</span><div><strong>{value}</strong><small>{suffix}</small></div></article> }
function PanelTitle({ title, subtitle, action }: { title: string; subtitle: string; action?: React.ReactNode }) { return <div className="panel-title"><div><h3>{title}</h3><p>{subtitle}</p></div>{action}</div> }
function StatusLine({ icon, label, status, active }: { icon: React.ReactNode; label: string; status: string; active: boolean }) { return <div className="status-line"><span className="status-line-icon">{icon}</span><span><b>{label}</b><small>{status}</small></span><i className={active ? 'active' : ''}/></div> }
function Empty({ icon, title, text }: { icon: React.ReactNode; title: string; text: string }) { return <div className="empty-state"><span>{icon}</span><b>{title}</b><p>{text}</p></div> }
function ReservationRow({ reservation, tokenEligible, tokenUnavailable, tokenLoading, onCopy, onRegenerate, onRevoke }: { reservation: { id: string; token: string; tokenSuffix?: string; date: string; state: string }; tokenEligible: boolean; tokenUnavailable: boolean; tokenLoading: boolean; onCopy: () => void; onRegenerate: () => void; onRevoke: () => void }) { const presentation = reservation.date < localDate() && ['disponible', 'conservada'].includes(reservation.state) ? { label: 'Vencida', tone: 'expired' } : ({ disponible: { label: 'Disponible', tone: 'available' }, conservada: { label: 'Conservada', tone: 'retained' }, estacionado: { label: 'En uso', tone: 'occupied' }, finalizada: { label: 'Finalizada', tone: 'finished' }, revocada: { label: 'Revocada', tone: 'revoked' }, vencida: { label: 'Vencida', tone: 'expired' } } as Record<string, { label: string; tone: string }>)[reservation.state] ?? { label: reservation.state, tone: 'unknown' }; const tokenLabel = reservation.token || (tokenLoading ? 'Cargando token…' : tokenUnavailable ? 'Token no recuperable' : 'Token no disponible'); return <div className={`reservation-row ${tokenEligible ? '' : 'reservation-row-disabled'}`} aria-disabled={!tokenEligible}><div className="reservation-token"><Ticket/><span><b>{tokenLabel}</b><small>ID {reservation.id.slice(0, 8)} · {reservation.date}</small></span></div><span className={`reservation-status ${presentation.tone}`} aria-label={`Estado: ${presentation.label}`}>{presentation.label}</span><span className="reservation-date">{reservation.date}</span>{tokenEligible && reservation.token && <button className="secondary-button" onClick={onCopy}><Copy size={15}/> Copiar token</button>}{tokenUnavailable && tokenEligible && isSupabaseConfigured && <button className="secondary-button" onClick={() => { if (confirm('Se generará un token nuevo y el anterior dejará de ser válido. ¿Continuar?')) onRegenerate() }}><RotateCcw size={14}/> Regenerar token</button>}{tokenEligible && isSupabaseConfigured && <button className="secondary-button" onClick={() => { if (confirm('¿Revocar esta reserva?')) onRevoke() }}>Revocar</button>}</div> }

export default App
