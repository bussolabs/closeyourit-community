import LiveFrameController from "controllers/live_frame_controller"

// CYRA-823 — l'attività di un agente si aggiorna da sola; il resto della sua scheda no.
//
// Il comportamento vive per intero in `live_frame_controller`, che dalla scheda di un sito osservato
// (CYRA-824) in poi serve più di una pagina: un segnale senza contenuto, una richiesta del frame
// fatta con la sessione di chi guarda, mai a scheda nascosta, una alla volta, e una riconciliazione
// a tempo per ciò che scade da solo senza che nessun evento lo racconti.
//
// Il nome `agent-activity` resta perché è quello che la scheda dichiara: due copie dello stesso
// controllore, invece, sarebbero due comportamenti che possono divergere in silenzio.
export default class extends LiveFrameController {}
