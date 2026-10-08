# Changelog

## [Unreleased]

## [0.181.1] - 2026-10-08

### Changed

- **La chiave Claude della macchina sta a sinistra.** Nella scheda «Dettagli e impostazioni» il riquadro è sotto i motori, nella colonna larga.

## [0.181.0] - 2026-10-08

### Added

- **Una chiave Claude per ogni macchina.** Nella pagina di una macchina puoi darle una chiave Claude sua, incollata o presa da un segreto del vault. Anche la chiave dell'organizzazione ora si può collegare al vault. La macchina usa la sua, poi quella dell'organizzazione, poi il proprio accesso. [Agenti](/member/agents)

## [0.180.0] - 2026-10-08

### Added

- **Solo i tuoi ticket ancora aperti.** La riga di comando e le integrazioni possono chiedere i ticket assegnati a te e non ancora conclusi, senza scorrere tutto il progetto.

## [0.179.4] - 2026-10-08

### Changed

- **Lo stato del ticket segue dove si trova il codice.** Quando il lavoro dell'automazione arriva in staging, il ticket passa in revisione; quando arriva in produzione, diventa risolto. Se annulli l'automazione prima dello staging, il ticket torna aperto.

## [0.179.3] - 2026-10-07

### Changed

- **L'indirizzo dell'amministratore non compare più negli esempi.** Seed di sviluppo, account di prova, mockup e test usano un indirizzo d'esempio. In produzione non cambia nulla finché non imposti `GOD_EMAIL`.

## [0.179.2] - 2026-10-07

### Changed

- **Manutenzione interna.** Una riga di codice scambiata per una credenziale bloccava la pubblicazione della versione open source. Per chi usa CloseYourIt non cambia niente.

## [0.179.1] - 2026-10-07

### Fixed

- **Compiti ogni ora dei Puckies nel cambio d'ora.** Nella notte in cui l'orologio torna indietro, un compito ripetuto ogni ora gira in entrambe le ore ripetute, senza saltarne una.

## [0.179.0] - 2026-10-07

### Added

- **Puckies, colleghi AI che lavorano da soli.** Leggono ticket, errori e log, propongono azioni da confermare, seguono regole, compiti a orario e memoria, anche in squadra, su Telegram, Slack e app. Si attivano quando l’organizzazione li configura.

### Security

- **Niente segreti con nomi di sistema.** Un segreto non può più chiamarsi PATH, LD_*, DYLD_*, NODE_OPTIONS o un altro nome che cambia come girano i comandi: vale per segreti di progetto, condivisi, personali, alias e richieste di modifica.
- **Il gateway AI non scrive le domande nel log.** Il testo delle richieste ai servizi AI (messaggi, input, query, documenti) resta fuori dal log del server: restano solo i dati tecnici.
- **Il gateway AI conta anche le risposte interrotte.** Una risposta chiusa dal cliente a metà entra comunque nel tetto mensile. Ogni chiave ha un limite di 60 richieste al minuto e una richiesta non può chiedere più di 32768 token.

## [0.178.0] - 2026-10-07

### Fixed

- **Le novità della 0.177.0 arrivano ora.** La versione 0.177.0 non era stata pubblicata: le sue novità entrano con questa.

### Security

- **Invii troppo grandi rifiutati.** Ogni canale di raccolta dati (log, visite, replay, web vitals, help desk) rifiuta subito un invio oltre 5 MB, come già facevano eventi e metriche.
- **Cron monitor solo dei progetti visibili.** Gli aggiornamenti in tempo reale dei cron monitor arrivano soltanto a chi vede quel progetto. [Cron monitor](/member/monitoring/cron)
- **Inviti con consenso.** Se l'email invitata ha già un account, l'invito si accetta solo dopo aver fatto accesso con quell'account: nessuno può aggiungerti a un'organizzazione al posto tuo.
- **Nuovo ticket senza fughe.** Aprendo il modulo del nuovo ticket con un progetto fuori dal proprio ambito, il modulo non ne mostra più i dati. [Ticket](/member/tickets)
- **Niente accessi CLI durante un'impersonazione.** Mentre impersona un utente, l'amministratore non può approvare o rifiutare un accesso CLI a suo nome.

## [0.177.0] - 2026-10-07

### Added

- **Aggiornare dall'app.** Su un server community l'amministratore vede quando esce una versione nuova e cosa cambia. Con «Aggiorna ora» il server fa il backup, installa la versione nuova e torna indietro da solo se non risponde.
- **Il supporter risponde alle domande.** Una macchina con il supporter acceso propone le risposte alle domande di chiarimento; il server le accetta solo se superano i controlli, altrimenti restano a una persona. Le risposte del supporter restano «Da rivedere» finché qualcuno non le segna come viste. [Ticket](/member/tickets)

### Fixed

- **Intestazioni delle tabelle sempre visibili.** Scorrendo una tabella lunga, i nomi delle colonne restano in cima alla pagina e non coprono più le righe nelle colonne che scorrono da sole.

## [0.176.1] - 2026-10-06

### Fixed

- **Le novità della 0.176.0 arrivano ora.** La versione 0.176.0 non era stata pubblicata: le sue novità entrano con questa. La cronologia del progetto mostra con un nome leggibile le impostazioni del supporter.

## [0.176.0] - 2026-10-06

### Added

- **Programmi da aggiornare.** Nella scheda Dettagli e impostazioni di una macchina, la tabella dei programmi installati mostra l'ultima versione e segna quelli da aggiornare. Il controllo si fa una volta al giorno. [Agenti](/member/agents)
- **Nuovo indirizzo app.closeyour.it.** L'app risponde anche su app.closeyour.it. www.closeyour.it funziona come prima.

### Changed

- **Pagina della macchina a schede.** Panoramica mostra i lavori in corso, una riga ciascuno, e i numeri in una striscia sottile. Lavorazioni elenca i ticket lavorati. Dettagli e impostazioni raccoglie macchina, motori e programmi installati. [Agenti](/member/agents)

## [0.175.1] - 2026-10-06

### Fixed

- **Le novità della 0.175.0 arrivano ora.** La versione 0.175.0 non era stata pubblicata: le sue novità entrano con questa. Le pagine delle chiavi Claude e OpenRouter hanno indirizzi più corti. [Agenti](/member/agents)

## [0.175.0] - 2026-10-06

### Added

- **Una chiave Claude per tutte le macchine.** Il proprietario incolla una volta la chiave Claude dell'organizzazione e ogni macchina certificata la riceve da sola. Nessuno può più rileggerla. Senza questa chiave, ogni macchina usa il proprio accesso, come prima. [Agenti](/member/agents)
- **OpenCode può rileggere il lavoro.** Scegli OpenCode come revisore e, nella pagina Automator, il modello OpenRouter. Il proprietario mette una volta la chiave OpenRouter dell'organizzazione e nessuno può più rileggerla. [Automator](/member/agents/automator)
- **Una scelta dei motori per tutta l'organizzazione.** Nella pagina Automator scegli una volta chi lavora e chi rilegge. Le macchine con i motori di partenza la seguono subito; quelle con una scelta propria la tengono e possono tornare a seguirla. [Automator](/member/agents/automator)

### Changed

- **Pagina ticket più ordinata.** La discussione si legge come un'unica cronologia e ogni scheda cambia tutta la pagina. Le revisioni si aprono con l'esito e con chi ha riletto; una revisione respinta mostra giudizio e problemi in modo leggibile. [Ticket](/member/tickets)
- **Valutazione iniziale più chiara.** La valutazione dell'automazione si apre con l'avviso, poi i fatti e i motivi. Il pannello Agenti dice l'esito già nel titolo. [Ticket](/member/tickets)
- **Scegli per nome chi rilegge il lavoro.** Nella pagina di ogni macchina indichi quale motore rilegge il lavoro prima della consegna: Claude o Codex. Ogni macchina tiene la scelta che aveva. [Agenti](/member/agents)

### Fixed

- **Soste dell'automazione spiegate.** Quando l'automazione passa la mano a una persona, il ticket mostra l'ultimo motivo dell'agente. I controlli annullati o mai partiti risultano non eseguiti, non falliti. [Ticket](/member/tickets)
- **Scelte multiple da tastiera.** Il menu resta aperto dopo ogni scelta e conserva l’opzione evidenziata. I pulsanti delle fasi e delle revisioni seguono lo stile comune. [Ticket](/member/tickets)

## [0.174.0] - 2026-10-05

### Added

- **Domande durante la lavorazione.** Le domande ancora aperte compaiono anche nella scheda Automazione. Rispondere permette alla lavorazione di proseguire; ritirare una domanda non chiude il tentativo. [Ticket](/member/tickets)

### Changed

- **Resoconti più leggibili.** Il risultato della lavorazione viene prima dei dettagli. Puoi esplorare i passaggi dell’automazione in schede separate ed espandere le revisioni lunghe quando servono. [Ticket](/member/tickets)

### Fixed

- **Ricerca e selezioni più comode.** La ricerca apre le colonne che contengono risultati, inclusi i ticket conclusi meno recenti. I menu di selezione restano interamente visibili anche nelle colonne strette. [Ticket](/member/tickets)

- **Versioni dei crash nativi.** Le segnalazioni inviate dalle applicazioni C e C++ conservano la versione e l’ambiente di origine, anche quando questi dati arrivano insieme al rapporto di crash.

## [0.173.3] - 2026-10-05

### Changed

- **Tutti i progetti nella vista a schede.** La vista a schede mostra sempre tutti i progetti, divisi per gruppo, senza dover premere «Mostra altri». [Progetti](/member/projects)

## [0.173.2] - 2026-10-05

### Fixed

- **Finestre e pagine in ordine.** Il titolo di una finestra non si confonde più con quello della pagina, anche quando la finestra delle novità si apre da sola dopo un aggiornamento.

## [0.173.1] - 2026-10-05

### Fixed

- **Finestre coerenti.** Le finestre di dialogo usano la stessa struttura per titolo, contenuto e azioni, anche nel tema scuro.

- **Decisioni più chiare.** L’esito della revisione compare come notifica, lasciando il piano libero da azioni ripetute. [Approvazioni](/member/home/approvals)

## [0.173.0] - 2026-10-05

### Added

- **Ordina le approvazioni.** Puoi confrontare la versione dei piani e il tempo di attesa, ordinando le righe secondo la priorità che ti serve. [Approvazioni](/member/home/approvals)

### Fixed

- **Avvisi più leggibili.** Le notifiche restano leggibili anche con il tema scuro; la cronologia delle attività si apre nella finestra standard.

- **Installazione Community.** La copia pubblica conserva i permessi necessari per avviare l’applicazione.

## [0.172.0] - 2026-10-05

### Added

- **Capisci perché una macchina si ferma.** Il pannello mostra l’ultimo motivo di attesa o blocco comunicato dalla macchina. [Agenti](/member/agents)

- **Valuta un piano senza aprire il codice.** Le approvazioni spiegano cosa cambia e cosa succede dopo il tuo consenso; i riferimenti ai file restano consultabili. [Approvazioni](/member/home/approvals)

- **Trova una cosa da fare.** Cerca per nome della lista o per testo di una voce, anche nelle liste condivise con te. [Todos](/member/lists)

- **Cerca dalla panoramica.** La ricerca nelle pagine della conoscenza parte anche dalla pagina iniziale dell'area. [Conoscenza](/member/knowledge)

- **Correggi i tuoi messaggi.** Puoi modificare un messaggio già inviato. Se è cambiato nel frattempo, il tuo testo resta nel modulo senza sovrascrivere quello più recente. [Conversazioni](/member/chat/conversations)

- **Collega altre applicazioni.** La guida di installazione mostra le combinazioni provate e i loro limiti, distingue i candidati locali dai pacchetti pubblicati e permette di verificare la ricezione di un evento supportato. ([guida](/member/guides/installation))

- **Segui una richiesta tra servizi.** Vedi i passaggi ricevuti, i tempi e i collegamenti espliciti a errori e log. Quando mancano dati, la pagina lo dichiara. [Percorsi](/member/monitoring/traces) ([guida](/member/guides/traces))

- **Misure e avvisi.** Consulta le misure inviate dalle applicazioni, filtra per servizio e ambiente e imposta soglie per ricevere avvisi. I dati mancanti restano sconosciuti. [Misure](/member/monitoring/measurements) ([guida](/member/guides/measurements))

- **Sessioni per versione.** Confronta le sessioni per ambiente e versione. Gli esiti sconosciuti restano visibili e le richieste aggregate sono separate dalle sessioni singole. [Sessioni](/member/monitoring/sessions) ([guida](/member/guides/session-health))

- **Ritrova l’origine degli errori.** Con i file corrispondenti al rilascio puoi confrontare posizioni originali e dati ricevuti. Gli errori Java e i crash nativi richiedono anche servizi di elaborazione configurati. [Errori](/member/monitoring/error) ([guida](/member/guides/errors))

- **Lavori in background.** Le misure dei lavori distinguono nome, coda e tipo di misura quando l’app invia i nuovi dati di esecuzione. I gruppi storici restano invariati. [Performance](/member/monitoring/performance) ([guida](/member/guides/performance))

### Fixed

- **Sincronizzazione GitHub più chiara.** Il comando per sincronizzare resta accanto all’ultimo esito, con impostazioni e stato organizzati in due colonne.

- **Schede più stabili.** L’invito ad aprire una scheda compare senza aggiungere una riga quando passi con il puntatore.

- **Recupero completo degli errori.** La ricostruzione dei dettagli prosegue oltre i primi cento eventi senza salti o ripetizioni dovuti al fuso orario. [Errori](/member/monitoring/error)

- **Bozze pronte prima di scrivere.** I nuovi moduli diventano utilizzabili quando il ripristino della bozza è completato, così il primo testo inserito viene conservato e le schede rispondono subito. [Ticket](/member/tickets)

- **Accessi più rigorosi.** La gestione dei membri non può cambiare l’email di accesso. Approvazioni, credenziali e invio dei segreti a GitHub rispettano i limiti degli ambienti autorizzati.

- **Menu delle righe.** Aprire il menu di una riga non porta più alla scheda mentre stai scegliendo un'azione.

## [0.171.1] - 2026-10-04

### Fixed

- **Rilascio riparato.** La versione 0.171.0 non è andata online: questa porta le sue novità.

## [0.171.0] - 2026-10-04

### Added

- **Da richiesta a ticket.** Una richiesta di assistenza diventa un ticket con un clic, oppure si collega a un ticket che esiste già. Il ticket mostra quante richieste ha dietro. [Assistenza](/member/helpdesk) ([guida](/member/guides/helpdesk))

- **Rispondere a chi scrive.** Dalla richiesta di assistenza si risponde per email, e la risposta resta nella conversazione. Con l'AI configurata, le richieste simili compaiono insieme. [Assistenza](/member/helpdesk) ([guida](/member/guides/helpdesk))

- **L'errore accanto alla richiesta.** Se chi scrive ha avuto un errore durante la stessa visita, la richiesta di assistenza lo mostra, a un clic. Serve il pulsante «Serve aiuto?» della libreria per i siti. [Assistenza](/member/helpdesk)

### Changed

- **Il colore del gruppo vale per i suoi progetti.** Un progetto dentro un gruppo che ha un colore prende quel colore. Se cambi il colore del gruppo, cambiano anche i suoi progetti. [Progetti](/member/projects)

## [0.170.0] - 2026-10-03

### Added

- **Assistenza**: chi visita il sito di un progetto può scrivere al team. Le richieste arrivano in una pagina nuova e nella scheda Assistenza del progetto, dove trovi anche il codice pronto per il sito. Si accende dalle impostazioni del progetto. [Assistenza](/member/helpdesk) ([guida](/member/guides/helpdesk))

### Changed

- **Approvazioni più compatte.** I numeri dei passaggi stanno in una riga sola sotto il titolo, al posto dei riquadri grandi. Un clic su un numero filtra ancora la lista. [Approvazioni](/member/home/approvals)

## [0.169.2] - 2026-10-03

### Fixed

- **Rilascio riparato.** Le versioni 0.169.0 e 0.169.1 non sono andate online: questa porta le loro novità.

## [0.169.1] - 2026-10-03

### Fixed

- **Rilascio riparato.** La 0.169.0 non è andata online: questa versione porta le sue novità.

## [0.169.0] - 2026-10-03

### Added

- **Supporto**: nel piè di pagina c'è il pulsante Supporto. La pagina sale e compare un modulo per scrivere o dettare cosa non va. Con il messaggio parte anche la pagina in cui eri, così chi ti aiuta capisce prima. Sul telefono lo trovi nel menu.
- **Piè di pagina**: accanto a Supporto vedi quante tue richieste sono ancora aperte, con un clic per aprirle. La versione è un pulsante: un segnale «Novità» compare quando c'è un rilascio che non hai ancora guardato, e sparisce dopo averlo aperto. Lì accanto trovi anche le Guide e il menu della lingua.
- **Finestre**: quando si apre una finestra, la pagina dietro si sfoca. La cronologia vuota non ripete più «0 eventi».
- **Dettatura in «Chiedi ai ticket»**: puoi dettare la domanda con il microfono nel campo. Il microfono compare ovunque solo quando la trascrizione è collegata. [Chiedi ai ticket](/member/tickets/ask)
- **Todo**: sotto ogni lista, il campo per aggiungere una voce ora dice che basta premere Invio. [Todo](/member/lists)
- **Chiedi del progetto**: nell'intestazione di ogni progetto c'è un pulsante che apre l'assistente già fermo su quel progetto. Lì risponde solo su quello: ticket, errori, log, rilasci e il resto. La × sulla barra del progetto lo riporta su tutti i progetti. [Progetti](/member/projects)
- **L'assistente legge tutto il progetto**: oltre a ticket e knowledge, ora risponde anche su errori, operazioni lente, log, disponibilità, rilasci e idee di un progetto. Chiedi per esempio «quali errori ha Storefront?» o «qual è l'ultima versione?». ([guida](/member/guides/assistant))
- **Cosa chiedere all'assistente**: quando parli all'assistente, la schermata di ascolto mostra tre esempi di domande. Una guida nuova elenca tutto quello che sa fare, con le frasi da dire. ([guida](/member/guides/assistant))
- **Chiavi CloseYourIt AI.** Chi amministra crea chiavi per le installazioni che vogliono provare l'AI, ognuna con un tetto mensile. Raggiunto il tetto, l'AI di quella installazione si ferma con un messaggio chiaro fino al mese dopo.
- **Impostazioni AI.** Chi amministra sceglie da dove arriva l'AI: variabili del server, chiave CloseYourIt AI o un servizio compatibile OpenAI. «Prova collegamento» dice quali funzioni si accendono prima di salvare.
- **Tema scuro**: scegli fra chiaro, scuro o come il tuo sistema. Tutte le pagine hanno il loro aspetto scuro. [Preferenze](/member/preferences)
- **Nuovo in una finestra**: ogni «Nuovo» si apre in una finestra sopra la pagina, senza cambiare pagina. Quello che hai scritto resta anche se la chiudi per sbaglio.
- **Dettatura nei ticket**: con il microfono detti i commenti, le domande e la descrizione di un ticket nuovo. [Ticket](/member/tickets)
- **Errori collegati a un nuovo bug**: quando crei un bug puoi collegargli un errore aperto e un'operazione lenta dello stesso progetto. [Ticket](/member/tickets)
- **Codici di recupero da scaricare**: i codici di recupero della verifica in due passaggi si scaricano come file di testo.
- **Motore scelto per macchina**: per ogni macchina degli agenti scegli se lavora Claude o Codex, e se la revisione la fa lo stesso motore o l'altro.
- **Installazione su un server proprio**: CloseYourIt si installa con un comando, con aggiornamento, copia di sicurezza e ripristino. Funziona anche senza i servizi ospitati da noi.
- **Cerca e filtra nelle aree**: le tabelle delle aree hanno ricerca, filtro «Con problemi» e ordinamento su ogni colonna. I numeri in cima aprono la lista che contano. [Progetti](/member/projects)
- **Vault più facile da sistemare**: «Da sistemare» ha ricerca, filtri e un'azione su ogni riga. La cronologia dice in quale ambiente è successo ogni evento. [Vault](/member/vault)

### Changed

- **Numeri nella barra in alto**: accanto ai Todo, nella barra in alto e nel menu, compare quante cose restano da fare nelle tue liste. I numeri di Todo, chat e notifiche ora sono allineati alla loro icona.
- **Creato e aggiornato in fondo**: nelle pagine di dettaglio la riga con creato, aggiornato e cronologia resta attaccata al fondo della pagina, anche quando il contenuto è corto.
- **Pagina del progetto**: le informazioni sul progetto sono in cima alla colonna di destra e partono chiuse, con un clic per aprirle. I rilasci mostrano gli ultimi tre; «Vedi tutte» apre gli altri.
- **Pagine vuote**: quando una pagina non ha ancora niente da mostrare, il riquadro che lo spiega occupa tutta la pagina fino in fondo, con il testo al centro.
- **Funzioni AI senza servizio collegato.** Se l'AI non è collegata, l'assistente e le altre funzioni lo dicono chiaramente invece di dare un errore.
- **Perché è giù**: un sito o una macchina che non risponde dice il motivo sulla sua riga. Gli avvisi dicono dopo quanto tempo è tornato su.
- **Ticket più compatti**: le schede del ticket stanno nell'intestazione e ogni scenario è un blocco compatto, uguale nel modulo e nel dettaglio. [Ticket](/member/tickets)
- **Preferenze in un solo elenco**: tutte le preferenze stanno in un elenco con un unico Salva. [Preferenze](/member/preferences)
- **Pannello di amministrazione**: si apre su quello che richiede attenzione e i totali mostrano quanto sono cresciuti.

### Fixed

- **Testi più precisi**: i conteggi usano singolare e plurale giusti, i pulsanti dicono cosa fanno e le pagine vuote spiegano il primo passo.

## [0.168.1] - 2026-10-02

### Changed

- **Liste modificabili dalla pagina dei Todos.** Ogni lista è un pannello: spunti una voce, la togli con la × o ne aggiungi una scrivendo nell'ultima riga e premendo Invio. Nuova lista apre una finestra, senza cambiare pagina. [Todos](/member/lists)

## [0.168.0] - 2026-10-02

### Added

- **Cluster Kubernetes.** Aggiungi un cluster, installa l'osservatore con un comando e vedi macchine, app e una scheda con cosa non va adesso. Ricevi un avviso quando un'app riparte di continuo, funziona a metà o il cluster smette di mandare dati. L'osservatore guarda soltanto. [Cluster](/member/monitoring/clusters)

### Changed

- **Scheda di un server divisa in schede.** Si apre su una panoramica veloce: valori attuali, cosa sistemare e specifiche della macchina. Grafici, dischi, container, registro, operazioni e regole di avviso hanno ognuno la sua scheda. [Server](/member/monitoring/servers)
- **Dati del server più compatti.** Registro di sistema e regole di avviso sono tabelle, i grafici stanno due per riga e i database della macchina stanno sotto il loro pannello. [Server](/member/monitoring/servers)
- **Progetti in schede compatte.** I progetti sono schede piccole divise da linee sottili: ne vedi di più per riga, con errori, stato e ultima versione. [Progetti](/member/projects)

### Fixed

- **Contatori che non lampeggiano.** Cambiando pagina, il numero accanto ad Approvazioni e chi è online restano al loro posto invece di ripartire da zero.

## [0.167.1] - 2026-10-02

### Fixed

- **Rilascio riparato.** La 0.167.0 non è andata online: questa versione porta le sue novità.

## [0.167.0] - 2026-10-02

### Added

- **Header che si compatta.** La freccia in alto a destra riduce l'header a titolo, pulsanti e schede, e la scelta resta su ogni pagina e dispositivo. Anche scorrendo in basso l'header si compatta da solo. [Ticket](/member/tickets)
- **Una tabella per ogni area.** Osservabilità, Prodotto, Knowledge, Infrastruttura, Avvisi, Automazione, SEO e Vault mostrano una riga per progetto e una colonna per cosa controllare. Vedi subito quale progetto ha un problema e cosa manca da attivare. [Osservabilità](/member/observability)
- **Lingua nel piè di pagina.** Accanto a Privacy scegli fra English e Italiano: la scelta resta nel tuo account e la pagina si ricarica nella nuova lingua.
- **L'assistente prepara le azioni per te.** Chiedigli di aprire, commentare, spostare o assegnare un ticket, o di creare un todo o un'idea: ti mostra una scheda e non fa niente finché non premi Conferma. Puoi correggerla prima, scartarla o confermarle tutte insieme. [Assistente](/member/assistant/conversations)
- **Parla con l'assistente.** Premi il microfono in alto, di' quello che ti serve e invia: il testo arriva nella chat e l'assistente risponde con ricerche e schede da confermare. Se ha capito male, correggi il testo e rimanda. [Assistente](/member/assistant/conversations)

### Changed

- **Pannelli attaccati al bordo.** Su schermo grande i pannelli toccano il bordo della pagina senza margine e senza bordi doppi. Lo spazio tra un pannello e l'altro resta. Sul telefono non cambia niente.
- **Spiegazioni che si chiudono.** I messaggi di spiegazione e i consigli, come «Cosa fare adesso» del progetto o le cose da sistemare sui server, stanno in un riquadro in basso a destra. Lo chiudi con la X e non torna, finché non c'è qualcosa di nuovo.
- **Percorso sempre in cima.** Ogni pagina mostra dove sei, per esempio Home › Prodotto › Ticket, e ogni passo ti riporta indietro. [Ticket](/member/tickets)
- **Home con il suo header.** In cima alla Home trovi titolo, numeri della coda e i pulsanti per vedere tutte le decisioni o riprendere quella saltata.
- **Impostazioni del progetto una sezione alla volta.** Il menu a sinistra apre una sezione per volta, e ogni sezione ha il suo Salva. Ricaricando o mandando il link si apre la stessa sezione. [Progetti](/member/projects)
- **Ambienti del progetto in tabella.** Gli ambienti stanno in colonna e le voci in riga, così li confronti a colpo d'occhio. I server si collegano da una finestra apposta. [Progetti](/member/projects)
- **Guide con l'indice.** A sinistra trovi l'elenco di tutte le guide divise per argomento, a destra la guida aperta. I pulsanti di ogni guida stanno in alto. [Guide](/member/guides)
- **Informazioni di contorno affiancate.** Chi può leggere un segreto, come è protetto e come si usa, e spiegazioni simili, stanno una accanto all'altra invece che una sotto l'altra. [Vault](/member/vault)
- **Server filtrati per gruppo.** Database, produzione e staging sono un filtro della tabella, ognuno col suo numero. [Server](/member/monitoring/servers)
- **Indirizzi più corti.** Gli indirizzi delle pagine usano parole singole. I link vecchi, anche quelli già ricevuti via email o Telegram, portano alla pagina giusta.
- **Icone tutte nello stesso stile.** Ogni icona dell'app ora è vuota e disegnata allo stesso modo, anche nella barra laterale e sul sito pubblico. Le icone già scelte per progetti e gruppi restano le stesse, nel nuovo stile.
- **Nuovo carattere più leggibile.** Testi e titoli sono in Atkinson Hyperlegible Next, codici e numeri in Atkinson Hyperlegible Mono. Le lettere simili, come 0 e O o 1, l e I, non si confondono più.
- **Tabella dei segreti in un pannello solo.** Ricerca, conteggi, pulsanti e tabella stanno insieme. Le variabili si sfogliano 12 alla volta e la variabile cercata si apre sulla sua pagina. Sul telefono ogni variabile diventa una scheda con un ambiente per riga.
- **Segreti di progetto più ordinati.** Variabili, file, valori su misura e registro accessi sono schede. In alto vedi quante variabili ha ogni ambiente; un clic su «Anomalie» mostra solo quelle che mancano da qualche parte. Le letture uguali stanno in una riga sola.
- **Assistente più comodo.** Dal pannello apri tutte le tue conversazioni, con data, numero di messaggi, inizio della risposta e ricerca. Nella conversazione Invio invia e trovi domande d'esempio. Le conversazioni si cancellano 30 giorni dopo l'ultimo messaggio. [Assistente](/member/assistant/conversations)
- **L'assistente cerca nei tuoi dati.** Puoi chiedergli dei tuoi ticket, delle pagine della knowledge base o dello stato di un progetto: risponde con quello che trova e ti indica ancora la pagina giusta. Vede solo ciò a cui hai accesso. [Assistente](/member/assistant/conversations)
- **Liste Da fare più pratiche.** Ogni lista mostra una barra di avanzamento, le prossime voci e con chi è condivisa; puoi sceglierne il colore e riordinarle trascinandole. Le voci fatte finiscono in «Completate», e una voce si rinomina con un clic. [Da fare](/member/lists)
- **Pagine d'ingresso delle aree più ordinate.** Ogni area dice cosa contiene e mostra le pagine con la stessa scheda; quelle da attivare stanno in fondo. Avvisi mostra regole, notifiche e canali, Amministrazione è divisa in tre gruppi e SEO senza siti invita ad aggiungerne uno.
- **Liste da 12 righe.** Le liste mostrano 12 righe per pagina invece di 10, e sotto una lista vuota non compare più «0–0 di 0». Le schede dei progetti e il pannello dell'assistente non hanno più l'ombra. [Progetti](/member/projects)
- **Milestone più chiare.** Nell'elenco cerchi e filtri per stato, vedi quanti ticket sono chiusi e quando scade ogni milestone; le inattive stanno in fondo. Aprendone una trovi i Dettagli a destra, attivi o disattivi con un interruttore e i ticket chiusi sono raccolti in fondo.
- **Menu stretto più comodo.** Col menu laterale stretto, passa sopra l'icona di un'area: accanto compaiono le sue pagine, come Errori o Log. Un pallino segnala approvazioni e messaggi in attesa, e una linea separa le sezioni.

### Fixed

- **Bacheca senza scorrimento a vuoto.** Le pagine Ticket e Carico di lavoro non scorrono più quando non c'è altro da vedere. [Ticket](/member/tickets)
- **Menu laterale fermo al suo posto.** Aprendo una voce, il menu resta dove l'avevi lasciato invece di tornare in cima. Vale anche per l'indice delle guide e di Amministrazione.

## [0.166.2] - 2026-10-01

### Changed

- **Conversazioni più chiare.** I tuoi messaggi stanno a destra, ognuno con l'ora, divisi per giorno. L'elenco ha la ricerca, l'ultimo messaggio sotto il nome e il filtro «Non letti». Eliminare un messaggio chiede conferma.

### Fixed

- **Rilascio riparato, di nuovo.** Né la 0.166.0 né la 0.166.1 sono andate online: questa versione porta le loro novità.

## [0.166.1] - 2026-10-01

### Fixed

- **Rilascio riparato.** La 0.166.0 non è andata online: questa versione porta le stesse novità.

## [0.166.0] - 2026-10-01

### Changed

- **Attività del team più ordinate**: passi da Bacheca a Lista accanto alla ricerca e la colonna Annullate resta chiusa finché non la apri. Sulle card vedi chi partecipa e la scadenza, colorata quando si avvicina. Nel dettaglio cambi lo stato dal riquadro Dettagli. [Attività del team](/member/workload/actions)
- **Approvazioni più leggere**: le fasi sono una fila di puntini e Approva resta sempre a destra, anche su schermi stretti. Codice, titolo e attesa stanno su una riga; un clic sulla riga apre l'anteprima, con l'agente. Annulla tutte è nel menu ⋯. [Approvazioni](/member/home/approvals)
- **Pagine vuote che spiegano**: quando una sezione non ha ancora niente, ti dice a cosa serve e come si riempie, con lo stesso aspetto in tutta l'app.
- **Idee più comode**: in lista vedi i voti e una riga del problema, e puoi passare alle card. Le chip in alto filtrano per stato con un clic. Nel dettaglio leggi prima il problema, tutto in un riquadro, e voti dalla colonna di destra. Archivia è nel menu ⋯. [Idee](/member/ideas)

## [0.165.2] - 2026-10-01

### Fixed

- **Filtri che non passano di mano**: se sullo stesso browser entra un'altra persona, non ritrova più i filtri e il periodo scelti da chi c'era prima. Questa versione porta online anche le novità della 0.165.0.

## [0.165.1] - 2026-10-01

### Fixed

- **Rilascio riparato.** La 0.165.0 non è andata online: questa versione porta le stesse novità.

## [0.165.0] - 2026-10-01

### Changed

- **Menu laterale più chiaro**: «Il mio lavoro» è fra le voci fisse, Approvazioni e Conversazioni mostrano quante cose ti aspettano e gli avvisi hanno un gruppo loro. Il nome di un gruppo apre la sua panoramica e le Guide sono in fondo. Su computer puoi restringere il menu alle sole icone.
- **Schede del ticket più ordinate**: Discussione viene subito dopo Dettaglio e un pallino ti avvisa quando l'automazione aspetta te. Automazione si apre come la card della Home, il Resoconto mostra cosa è cambiato dalla versione prima, le Domande risolte si raccolgono in fondo. [Ticket](/member/tickets)
- **Pagina del ticket più leggera**: a destra restano Agenti, Dettagli, Collegamenti e Contesto, con i riquadri vuoti nascosti. «Prendi in carico» sta accanto all'assegnatario e in fondo trovi gli ultimi commenti. [Ticket](/member/tickets)
- **Pagine più ordinate**: il menu laterale e il contenuto ora sono due pannelli chiari, staccati dai bordi. In cima a ogni pagina trovi il titolo, una riga che dice cosa contiene e i pulsanti accanto. Le spiegazioni lunghe restano nelle guide. ([guida](/member/guides))
- **Lo stato di ogni progetto nella lista**: ogni card dei progetti mostra gli errori aperti, se il sito è online e l'ultimo rilascio. Vedi subito quale progetto ha un problema, senza aprirli uno per uno. [Progetti](/member/projects)
- **Barra di ricerca più comoda**: in tutte le liste la barra di ricerca sta sopra la tabella e resta in vista mentre scorri. Una ✕ svuota la ricerca e il tasto / ci porta dentro. In Progetti puoi anche filtrare per gruppo e ordinare per errori, ticket o ultimo rilascio. [Progetti](/member/projects)
- **Scheda del progetto più ordinata**: nome, sigla, descrizione e pulsanti stanno su una riga. La salute è una striscia sola con l'ultimo rilascio, e a destra trovi prima monitoraggio e rilasci. Le schede meno usate sono nel menu «Altro». [Progetti](/member/projects)
- **Ambienti del progetto più chiari**: ogni ambiente ha la sua scheda, senza scorrere di lato. «Eredita» dice se il valore è attivo o spento, i server collegati stanno accanto al loro interruttore e vedi token e stato del monitor. Prima di disattivare un ambiente ti chiede conferma. [Progetti](/member/projects)
- **Decidere dalla home è più veloce**: il primo rischio di un piano si legge subito, senza clic. In alto vedi che tipo di decisioni aspettano e da quanto; sotto il pulsante leggi cosa succede dopo il sì. Le modifiche ai segreti in Production dicono cosa si ferma se il valore è sbagliato. [Home](/)
- **Decisioni in pezzi brevi**: piani e consegne arrivano con una frase su cosa succede se approvi, fino a tre punti e il livello di rischio. Le consegne mostrano criteri e test contati, come dichiarati dall'agente. Alle domande dell'agente rispondi scegliendo una risposta proposta.
- **Nuovo carattere**: l'interfaccia usa IBM Plex. Testi e titoli sono in IBM Plex Sans; codici, numeri ed etichette in IBM Plex Mono, così i dati si distinguono a colpo d'occhio.
- **Barra in alto più chiara**: il nome dell'organizzazione si legge intero e ognuna ha il suo colore. Un pallino dice se sei connesso e «Solo tu» se non c'è nessun altro. La ricerca mostra ⌘K e la campanella apre le ultime notifiche senza cambiare pagina.
- **Ricerca che trova tutto**: ⌘K apre una finestra al centro con la pagina sfocata dietro. Trova anche pagine dell'app, idee, monitor, server, persone, libri, conversazioni e nomi dei segreti, solo tra ciò che puoi vedere. Filtri per tipo, recenti e Invio per aprire.
- **Approvazioni più rapide**: le richieste sono raggruppate per tipo di decisione e in alto vedi quante sono ferme in ogni passaggio. Approvi dalla riga, apri un'anteprima senza cambiare pagina e ti muovi con i tasti j e k. L'attesa si colora quando si allunga. [Approvazioni](/member/home/approvals)
- **Bacheca dei ticket più compatta**: passi da Bacheca a Lista con l'interruttore accanto alla ricerca, e i filtri in comune restano. Sulle card la priorità è una freccia accanto al codice e gli avvisi sono icone: ogni colonna mostra più ticket. [Ticket](/member/tickets)
- **Pagina Errori più ordinata**: il periodo è un filtro come gli altri e compare solo se lo cambi. Il ticket sta accanto allo stato, c'è il menu «Ordina» e ogni riga mostra l'andamento. Se arrivi da un progetto, la pagina lo nomina. Se la lista è vuota, dice quando è arrivato l'ultimo errore. [Errori](/member/monitoring/error)
- **Impostazioni del progetto in una pagina sola**: I token di ingest ora stanno nelle Impostazioni del progetto, accanto alle origini consentite. Un indice a sinistra ti porta a ogni sezione, il Project ID si copia sempre e i token si cercano e si filtrano per stato. Chi gestisce solo i token vede solo la loro sezione. [Progetti](/member/projects)
- **Documenti del progetto più comodi**: carichi i file dal pulsante nella barra di ricerca o trascinandoli sulla lista. Le colonne si ordinano, la descrizione si vede sotto il nome, un clic su un tag filtra e PDF e immagini si aprono senza scaricarli. [Progetti](/member/projects)

### Removed

- **Roadmap tolta**: le pagine Roadmap dei ticket e del progetto non ci sono più. Le milestone restano: le assegni dal ticket e le trovi nella scheda Milestone del progetto.

## [0.164.0] - 2026-09-30

### Changed

- **Lo spostamento di un progetto porta con sé la sua Conoscenza**: le pagine della Conoscenza collegate solo a ciò che sposti partono con lui, con cronologia, allegati e libro. Un lavoro degli agent fermo da tempo non blocca più lo spostamento. ([guida](/member/guides/project-moves))

## [0.163.0] - 2026-09-30

### Added

- **Spostare un progetto in un'altra organizzazione**: se sei proprietario di due organizzazioni, puoi spostare un progetto o un intero gruppo dall'una all'altra. Prima vedi cosa lo blocca e cosa cambia; secret, ticket e chiavi restano validi. ([guida](/member/guides/project-moves))

## [0.162.0] - 2026-09-29

### Changed

- **Il README spiega come avviare solo i lavori in background.** Nella sezione Sviluppo locale c'è `bin/jobs`, che avvia il worker Solid Queue senza il server web. (CYRA-881)

## [0.161.0] - 2026-09-29

### Changed

- **Il README indica la cartella vera delle soluzioni ai problemi.** La sezione Troubleshooting punta a `~/Lavoro/Github/Personale/commons/knowledge-base/troubleshooting/`, non più al vecchio rimando. (CYRA-880)

## [0.160.0] - 2026-09-29

### Changed

- **Il README dà l'indirizzo di staging.** Il README dice su quale indirizzo risponde staging. Quando resta inattivo si ferma e la prima richiesta può impiegare decine di secondi per risvegliarlo. (CYRA-878)

### Fixed

- **Due lavorazioni in attesa di produzione non condividono più il numero di versione.** La seconda prende il numero successivo, e la produzione usa lo stesso numero della sua prova su staging. (CYRA-878)
- **La scheda non dice «Bloccato» mentre la lavorazione riprova da sola.** Un passo respinto e già in un nuovo tentativo si legge «In lavorazione» e non chiede niente. (CYRA-877)
- **Una lavorazione annullata o finita dice che è finita.** Non scrive più «va avanti da sola» sotto «Annullato». (CYRA-876)

## [0.159.0] - 2026-09-29

### Changed

- **Il README spiega come si rilascia.** Un tag di prova porta la versione solo su staging. Un tag stabile, con la sua voce nel CHANGELOG, la porta anche in produzione. Il rilascio passa sempre da GitHub Actions. (CYRA-877)

## [0.158.0] - 2026-09-29

### Fixed

- **La scheda Automazione non chiama più «approvato» un passo bloccato.** Un tentativo che ha consegnato un blocco ora si legge «bloccato», in arancione, e non finisce raggruppato con quelli riusciti. (CYRA-876)
- **Il rilascio su staging viene riconosciuto.** Il controllo che il codice approvato sia sulla linea principale leggeva al contrario il confronto di GitHub e fermava ogni rilascio già riuscito. (CYRA-876)

## [0.157.3] - 2026-09-28

### Fixed

- **Gli avvisi sui servizi di CloseYourIt restano a noi.** Gli avvisi su intelligenza artificiale, ricerca per significato e memoria temporanea non arrivano più ai membri delle organizzazioni. Riguardano il funzionamento di CloseYourIt e li seguiamo noi.

## [0.157.2] - 2026-09-28

### Fixed

- **Niente più argomenti doppi su Telegram.** Nel gruppo Telegram gli avvisi restano nel loro argomento anche quando uno viene rifiutato. Gli avvisi molto lunghi arrivano accorciati invece di andare persi.

## [0.157.1] - 2026-09-27

### Fixed

- **Rilasci più affidabili.** Prima di ogni rilascio le prove automatiche girano di nuovo per intero, anche quando GitHub risponde a singhiozzo. Per chi usa CloseYourIt non cambia niente.

## [0.157.0] - 2026-09-27

### Added

- **Il costo di ogni lavorazione delle macchine.** CloseYourIt registra quanto costa ogni tentativo di un agente e con quale modello. Da qui nasce il resoconto settimanale dei costi per fase e per progetto.

## [0.156.0] - 2026-09-26

### Added

- **Un rilascio che non sta in piedi apre un ticket.** Se dopo un rilascio la produzione non risponde o mostra la versione sbagliata, CloseYourIt apre un ticket per il responsabile del progetto, uno per versione. Arriva anche per i rilasci fatti dalle macchine. [Ticket](/member/tickets)

## [0.155.0] - 2026-09-26

### Added

- **Ferma un rilascio prima della produzione.** Nell'elenco delle lavorazioni che vanno avanti da sole, un rilascio in attesa dice da che ora parte e ha il tasto «Ferma». Finché resta fermo, nessun rilascio di quel repository va in produzione. [Approvazioni](/member/home/approvals)

## [0.154.1] - 2026-09-25

### Changed

- **Freno prima della produzione.** Un rilascio preparato dalle macchine va in produzione solo dopo 2 ore di prova in staging. Se in quelle ore compare un errore nuovo, resta fermo finché non lo risolvi o lo ignori. La scheda del ticket dice fino a quando aspetta.

## [0.153.0] - 2026-09-23

### Fixed

- **Stesso esito sulla stessa pagina di conoscenza.** Una pagina rifiutata e rimandata identica riceveva a volte una risposta diversa. Ora l'esito è sempre lo stesso, e il rifiuto mostra il passaggio del testo che lo ha motivato. [Knowledge base](/member/knowledge)

### Changed

- **Una sola approvazione per ticket.** Approvi il piano e basta: quando i controlli automatici e la rilettura del codice sono positivi, il lavoro consegnato va avanti da solo verso il rilascio. Se qualcosa non torna, la decisione resta tua, con il motivo scritto. [Approvazioni](/member/home/approvals)

## [0.152.0] - 2026-09-23

### Added

- **Ripartire da zero con le lavorazioni.** Owner e admin possono annullare in un colpo tutte le lavorazioni automatiche aperte, dopo una conferma. Le code si svuotano e i ticket restano, senza automazione. [Approvazioni](/member/home/approvals)

## [0.151.0] - 2026-09-23

### Added

- **Filtro per Gruppo sui ticket.** In lista, bacheca e roadmap puoi scegliere uno o più Gruppi: vedi insieme i ticket di tutti i loro progetti. Si combina con gli altri filtri e si salva nelle viste. [Ticket](/member/tickets)

## [0.150.0] - 2026-09-23

### Changed

- **Un'icona per ogni argomento del gruppo Telegram.** Nel gruppo del proprietario ogni argomento ha la sua icona: 🔥 Critico, 💻 Server, 📝 Ticket, 🦠 Errori e così via. Gli argomenti già creati la prendono ricollegando il gruppo. [Telegram](/member/preferences/telegram)

## [0.149.0] - 2026-09-23

### Added

- **Avvisi del proprietario in un gruppo Telegram.** Il proprietario può collegare un suo gruppo Telegram con gli argomenti: ogni avviso arriva nel suo argomento, come Critico, Server, Ticket o Errori. Gli altri utenti continuano a riceverli in privato. [Telegram](/member/preferences/telegram)

### Changed

- **Niente più avvisi doppi.** Se un avviso ti arriva su Telegram, non ti arriva anche per mail. La mail parte solo quando Telegram non riesce a consegnarlo. [Notifiche](/member/preferences/notifications)

## [0.148.0] - 2026-09-23

### Changed

- **Decisioni più leggere in home.** Ogni scheda mostra un riassunto corto e solo le azioni principali: attenzione, rischi e le altre scelte si aprono con un clic. Puoi decidere anche da tastiera: a approva, r respinge, s salta, d rimanda. [Home](/)
- **Pagine più facili da leggere.** Abbiamo ripassato una per una le pagine dell'app: parole tecniche tradotte, numeri non più ripetuti, date che dicono «… fa», plurali corretti e colonne che non vanno più a capo.
- **Guide allineate ai menu.** Le guide chiamano menu e schede con i nomi che vedi davvero nell'app, e usano meno gergo. [Guide](/member/guides)
- **Assistente in ordine.** L'elenco e le conversazioni dell'assistente hanno margini e intestazione come le altre pagine; a elenco vuoto spiega a cosa serve. [Assistente](/member/assistant/conversations)
- **Pagina di stato in italiano corretto.** In italiano la percentuale si legge con la virgola, «1 parziale» è al singolare e la scheda annuale dice «1a».
- **Revisioni senza resoconto riconoscibili.** Le revisioni che non hanno un resoconto del lavoro portano un'etichetta, così le trovi e le decidi insieme. In home, al posto del resoconto mancante, compare l'inizio della descrizione del ticket. [Approvazioni](/member/home/approvals)

### Fixed

- **Grafici nel tempo completi.** I grafici a blocchi di uptime, errori, performance e server non perdono più un blocco: l'ultimo periodo non resta vuoto. [Uptime](/member/monitoring/monitors)
- **Delega dei file condivisi più sicura.** La scelta del progetto parte vuota: un clic distratto su «Delega» non affida più il file al primo progetto della lista. [Secret condivisi](/member/shared/secrets)
- **Tutte le variabili personali raggiungibili.** I numeri di pagina stanno sotto la lista e compaiono anche senza attività recente. [Secret personali](/member/personal/secrets)
- **Sessioni attive vere.** Il pannello di amministrazione conta solo le sessioni ancora valide, non gli accessi scaduti.
- **Testi in italiano dove mancavano.** Il messaggio del login, «Letto da» e «sta scrivendo» della chat restano nella tua lingua. [Chat](/member/chat/conversations)
- **Workflow «In corso».** Il collegamento apre di nuovo la vista delle lavorazioni in corso. [Workflow](/member/workflows)
- **Privacy con piè di pagina.** L'informativa ha il menu e la firma del sito come le altre pagine pubbliche.

## [0.147.3] - 2026-09-16

### Fixed

- **I dati dei server non aspettano più dietro alle misure delle altre applicazioni.** Hanno una corsia di lavoro tutta loro, quindi un'applicazione che manda molte segnalazioni non può più far risultare «fermo» un server che sta benissimo. (CYRA-850) [Server](/member/monitoring/servers)
- **Nessuna applicazione può occupare da sola tutta la ricezione delle misure.** Ora resta sempre un posto libero per le altre. (CYRA-850)

## [0.147.2] - 2026-09-16

### Fixed

- **Rilascio tecnico.** Le correzioni di questa versione sono arrivate complete con la 0.147.3.

## [0.147.1] - 2026-09-16

### Fixed

- **Basta avvisi «dati fermi» su server che stanno benissimo.** Quando la ricezione dei dati andava in ritardo, il sistema misurava quel ritardo e la misura stessa allungava la coda. Ora quelle misure non vengono più raccolte e la coda rientra da sola. (CYRA-849) [Server](/member/monitoring/servers)

## [0.147.0] - 2026-09-14

### Added

- **Un avviso quando la memoria temporanea non risponde.** Prima il guasto restava scritto solo nei registri tecnici. Ora arriva un avviso in app e via email. Durante il guasto le notifiche verso Slack e Discord possono tacere: adesso si sa perché. (CYRA-846)

### Fixed

- **Le domande riservate non arrivano più al cliente.** Le domande nate riservate, come quelle poste dagli automi, erano visibili a chiunque vedesse il ticket, contatori compresi. Ora le leggono solo le persone interne all'organizzazione. (CYRA-848) [Ticket](/member/tickets)
- **I ticket rimasti senza parere tornano in coda da soli.** Se la valutazione che decide se un ticket può andare a un agente non veniva prodotta, il ticket restava fermo finché qualcuno non lo sbloccava a mano. Ora un controllo orario li ripesca. (CYRA-847) [Ticket](/member/tickets)
- **La modifica parziale dal terminale non cancella più il resto.** Cambiare solo il nome di una regola di avviso ne perdeva progetto, livello e soglia; cambiare solo un asse di un team svuotava l'altro. Ora i campi non passati restano come sono. (CYCL-62)
- **Le icone tornano sui pulsanti delle pagine SEO.** Quattro pulsanti dell'area siti controllati restavano senza icona.

## [0.146.16] - 2026-09-10

### Fixed

- **Ricerca per significato, doppioni e pagine correlate tornano a funzionare.** Dal rilascio precedente la chiave del servizio AI non aveva i permessi per l'analisi dei testi e queste funzioni tacevano. Ora c'è una sola chiave, con tutti i permessi. [Ticket](/member/tickets)

## [0.146.15] - 2026-09-09

### Added

- **Nei ticket si allegano anche i video.** Ticket, commenti, chat, documenti di progetto e pagine della conoscenza accettano MOV, MP4, WEBM, MKV e AVI. Nel dettaglio ticket il video si guarda direttamente, senza scaricarlo. Tetto 20 MB per video negli allegati ticket. [Ticket](/member/tickets)
- **Monetizzazione, rischi ed evoluzioni sono campi dell'idea, non commenti.** Ogni idea ha due campi nuovi, «Monetizzazione» e «Rischi e vincoli». Un'evoluzione è un'idea a sé, proposta dal pulsante «Proponi evoluzione» e collegata alla base; due idee si possono anche collegare tra pari. I commenti restano per la discussione del team. (CYRA-845) [Idee](/member/ideas)

### Changed

- **La pagina dell'idea ha la colonna a destra come le altre.** Dettagli, audit, evoluzioni e idee collegate stanno a destra; problema, soluzione, casi d'uso e discussione a sinistra. (CYRA-845) [Idee](/member/ideas)

## [0.146.13] - 2026-09-09

### Added

- **Le domande senza risposta si vedono dalla lista ticket.** Ogni ticket con domande ancora aperte mostra un'etichetta col numero, sia in elenco sia in bacheca; in cima c'è il contatore «Domande aperte», che cliccato mostra solo quei ticket. (CYRA-844) [Ticket](/member/tickets)

### Fixed

- Il controllo dei contratti usa un commit pubblicato del workflow canonico; il riferimento precedente era inesistente e impediva l’avvio dei job.

### Changed

- Generazione, revisione della conoscenza, embedding e rerank usano una sola `AI_API_KEY` per ambiente. Richiede una chiave con permessi `vlm-fast`, `embed-small` e `rerank` prima del deploy; nessun fallback alle vecchie chiavi. (CYRA-841)

## [0.146.11] - 2026-09-08

### Fixed

- **Nomi degli eventi nel filtro delle regole di avviso.** Nel filtro Evento tre voci (vulnerabilità, versione senza aggiornamenti, rilievo SEO) comparivano con nomi interni in inglese. Ora hanno lo stesso nome del modulo della regola, in italiano e in inglese. (CYRA-838)
- **Interruttori AI con nome e spiegazione.** Nelle impostazioni della piattaforma i due interruttori che si chiamavano solo «Label» ora dicono quale funzione controllano e cosa succede spegnendoli, in italiano e in inglese. (CYRA-840)
- **I passaggi della lavorazione tornano in italiano.** Nella Home e nel dettaglio di una decisione i sei passaggi mostrano gli stessi nomi della guida, nella lingua scelta, invece di nomi inglesi o messaggi di traduzione mancante. (CYRA-837)
- **Paginazione leggibile sul telefono.** In fondo alle liste i pulsanti delle pagine ora stanno su una riga sotto il conteggio, tutti dentro lo schermo: non serve più spostare la pagina di lato per andare avanti. (CYRA-839)

## [0.146.10] - 2026-09-08

### Changed

- **Nomi nel codice in una lingua sola**: le funzioni e le variabili che erano in italiano ora hanno nomi in inglese, come il resto del codice, e la regola è scritta nelle istruzioni del progetto. Per chi usa l'app non cambia niente (CYRA-803).
- **Sfogliare gli elenchi del monitoraggio è più rapido**: negli errori, nelle prestazioni e nei log, cambiare pagina o riordinare aggiorna soltanto l'elenco invece di ricaricare tutta la pagina. Numeri in alto e filtri restano al loro posto e l'indirizzo segue quello che vedi. [Errori](/member/monitoring/error) · [Log](/member/monitoring/logs)

### Fixed

- **Una modifica rifiutata non salva più nulla a metà**: se cambi più campi di un ticket e uno viene rifiutato, ad esempio lo stato o il traguardo, il ticket resta com'era. Niente campi salvati a metà, niente eventi né avvisi spuri (CYRA-788).

## [0.146.9] - 2026-09-07

### Fixed

- **Email soltanto alle persone**: gli account di servizio sono esclusi dagli avvisi di progetto e organizzazione. Anche le email già accodate vengono bloccate prima della spedizione, preservando gli eventuali destinatari umani (CYRA-836).
- **Riquadri con navigazione autonoma**: il recupero globale delle pagine non interferisce più con i riquadri che gestiscono da soli la navigazione, come l'assistente.
- **Domande nelle Approvazioni**: il chiarimento richiesto dalla lavorazione automatica mostra correttamente il testo della domanda.

## [0.146.8] - 2026-09-07

### Changed

- **Discussione del ticket senza righe di servizio nascoste**: quando la lavorazione automatica chiede un chiarimento, il commento che lo annuncia non porta più codice nascosto in coda. Le domande si leggono e si rispondono nella scheda Domande, come prima. [Ticket](/member/tickets)
- **Approvazioni: dopo una decisione si ricarica solo il necessario**: la pagina aggiorna insieme conteggi, elenco e richiesta successiva, invece di rifarsi tutta. I filtri accesi e il messaggio dell'esito restano dov'erano. [Approvazioni](/member/home/approvals)
- **La scheda di un agente si aggiorna da sola**: mentre guardi cosa sta facendo una macchina, l'attività si aggiorna senza ricaricare la pagina, e il periodo e la pagina dello storico restano dove li avevi lasciati. Sfogliare i lavori passati ora carica solo l'elenco. [Agenti](/member/agents)
- **Aggiornamenti solo del progetto che stai guardando**: se negli elenchi di errori, performance o log hai scelto un progetto, la pagina si aggiorna da sola soltanto quando arriva qualcosa di quel progetto. Prima si ricaricava anche per gli altri. Senza filtro non cambia niente. [Errori](/member/monitoring/error)
- **Scheda progetto: sfogli i ticket senza rifare la pagina**: cambiando pagina o filtro si aggiornano solo l'elenco dei ticket e il suo conteggio. La cronologia delle attività si carica quando la apri, poche per volta, e nel riquadro Audit resta l'ultima modifica. [Progetti](/member/projects)
- **La scheda di un sito si aggiorna da sola**: mentre aspetti un controllo, esito, conteggi e velocità compaiono senza ricaricare la pagina. Se il controllo non riesce trovi scritto perché, e i numeri buoni di prima restano al loro posto. [SEO](/member/monitoring/sites)

### Fixed

- **Filtri delle Approvazioni**: quando le decisioni in attesa sono tante, i progetti e le macchine con più lavoro non nascondono più gli altri. Ogni progetto resta nell'elenco, sceglierlo mostra davvero le sue decisioni e i conteggi in cima parlano solo di quello che hai scelto. [Approvazioni](/member/home/approvals)

### Security

- **Un'autorizzazione dal terminale vale per un accesso solo**: se il terminale la richiede due volte nello stesso istante, ne esce un accesso soltanto. Prima potevano uscirne due, entrambi validi. E se il rilascio non va a buon fine, non resta in giro nessun accesso utilizzabile.

## [0.146.7] - 2026-09-07

### Fixed

- **Nomi delle schede del ticket in italiano**: aprendo un ticket, la scheda dove si fanno e si leggono le domande si chiama Domande, come dice la guida. Prima portava un nome inglese. Per chi usa l'inglese resta Questions. [Ticket](/member/tickets)
- **Stato e priorità del ticket subito visibili sul telefono**: aprendo un ticket dal telefono, stato e priorità si leggono sotto il titolo, accanto ai comandi. Prima bisognava scorrere oltre tutto il testo per trovarli. Su schermo grande restano dove sono sempre stati. [Ticket](/member/tickets)
- **Ultimo controllo SEO: data e pagine dello stesso giro**: nell'elenco dei siti il numero di pagine viste ora è quello del controllo più recente, lo stesso che leggi nella scheda del sito. Prima poteva arrivare da un controllo precedente. [SEO](/member/monitoring/sites)

## [0.146.6] - 2026-09-07

### Fixed

- **Pagine da archiviare più facili da trovare**: nella revisione della conoscenza le pagine accettate che aspettano di finire nei documenti si sfogliano poche per volta e si cercano per titolo. Dai conteggi in alto salti direttamente al riquadro che ti serve. [Revisione](/member/knowledge/reviews)
- **Approvazioni: il numero e la frase dicono la stessa cosa**: nella panoramica Automazione il riquadro Approvazioni conta a parte quello che aspetta una tua decisione e quello che aspetta la risposta di qualcun altro. «Nessuna decisione in attesa» compare solo a coda vuota. [Automazione](/member/automation)
- **Filtri dei log a portata di mano sul telefono**: aprendo i log dal telefono, periodo, Filtri e Viste restano dentro lo schermo. Adesso scorrono di lato soltanto il grafico e la tabella, non tutta la pagina. [Log](/member/monitoring/logs)
- **Contatori delle performance in linea con i filtri**: periodo, progetto, stato e ricerca ora valgono anche per i numeri in alto, e quelli per categoria si cliccano per filtrare. Il tempo si chiama «Tempo totale storico»: dice quanto hanno consumato i gruppi da quando esistono. [Performance](/member/monitoring/performance)
- **Avvisi della macchina che stai guardando**: dalla scheda di una macchina, «Avvisi scattati qui» mostra ora soltanto i suoi avvisi, con il nome in alto e un modo per tornare a vederli tutti. Prima si apriva l'elenco completo o quello di tutte le macchine dello stesso progetto. [Notifiche](/member/alerting/notifications)

## [0.146.5] - 2026-09-07

### Security

- **Risposte dell'assistente sempre allineate ai tuoi accessi**: se l'accesso a un progetto ti viene tolto mentre una domanda è in corso, la risposta non usa più i dati di quel progetto e l'assistente ti dice che il tuo accesso è cambiato. Vale anche per le domande su ticket e conoscenza. [Ticket](/member/tickets)

### Fixed

- **Un'azione sul server non blocca più tutte le altre**: se la macchina sparisce mentre l'azione è in corso, dopo un po' viene segnata come interrotta e il posto si libera, così puoi lanciarne un'altra. Una volta segnata come interrotta non riparte da sola. Se l'esito arriva in ritardo, viene mostrato. [Server](/member/monitoring/servers)
- **Le decisioni sulle vulnerabilità restano dove le hai messe**: aggiornare una libreria non azzera più le altre vulnerabilità dello stesso file. Quelle che avevi ignorato o collegato a un ticket restano com'erano, con la loro data di prima comparsa. [Vulnerabilità](/member/monitoring/vulnerabilities)
- **Le vulnerabilità non spariscono per un file illeggibile**: se il controllo non riesce a leggere uno dei file delle dipendenze, le vulnerabilità di quel file restano in elenco e la pagina dice che il controllo è incompleto. Gli altri file vengono controllati come sempre. [Vulnerabilità](/member/monitoring/vulnerabilities)
- **I problemi SEO non spariscono per una pagina non letta**: se il controllo non riesce a leggere una pagina, i suoi problemi restano in elenco. Se ne vanno solo dopo un controllo riuscito che li trova risolti. La scheda del sito dice quante pagine non ha letto. [SEO](/member/monitoring/seo)
- **Controlli SEO su pagine molto pesanti**: una pagina enorme non blocca più il controllo del sito. La lettura si ferma alla parte che serve e il resto non viene scaricato, quindi il controllo prosegue sulle altre pagine come sempre. [SEO](/member/monitoring/seo)

## [0.146.4] - 2026-09-07

### Fixed

- **Registrazioni complete anche quando arrivano a raffica**: se i pezzi di una sessione registrata arrivano tutti insieme, il riepilogo continua a contare bene eventi e pagine visitate e nessun pezzo del filmato va perso. Prima l'ultimo salvato poteva cancellare quello arrivato insieme a lui. [Session replay](/member/monitoring/replays)
- **Nessun avviso dei siti va più perso.** Se l'avviso di un sito caduto o tornato attivo non riesce a partire, viene consegnato lo stesso entro pochi minuti, una volta sola. Prima poteva sparire e non arrivare mai, e lo stesso valeva per i promemoria del certificato e della lentezza. [Uptime](/member/monitoring/monitors)

### Changed

- **Log raggruppati più leggeri**: la vista che raggruppa i messaggi uguali si apre in fretta anche con molto storico alle spalle. Prima ogni apertura preparava tutti i gruppi per mostrarne una pagina sola. Conteggi, ordine e filtri restano gli stessi. [Log](/member/monitoring/logs)

## [0.146.3] - 2026-09-07

### Security

- **Ticket collegati**: un collegamento verso un ticket di un progetto che non puoi consultare non ne mostra più titolo, codice e stato. Resta scritto che il collegamento c'è e di che tipo è. Chi vede entrambi i progetti continua a usarlo come prima. [Ticket](/member/tickets)

### Fixed

- Il controllo dei metadati delle liste personali verifica anche il frammento aggiornato insieme alle spunte. (CYRA-828)

## [0.146.2] - 2026-09-07

### Fixed

- L’acquisizione di errori e metriche recupera le collisioni concorrenti sui gruppi. (CYRA-829)
- Gli heartbeat realtime seguono il ciclo di vita delle connessioni. (CYRA-830)
- Gli allegati testuali UTF-8 vengono letti correttamente nel vaglio agenti. (CYRA-833)
- I controlli degli agenti rispettano l’ordine delle scadenze. (CYRA-834)

### Fixed

- **Avanzamento delle Attività**: quando spunti una voce, il numero delle completate cambia subito insieme alla spunta. Se il salvataggio non riesce vedi un messaggio e la riga resta com'era davvero. [Attività](/member/lists)

### Changed

- **Consultazione più leggera**: i ticket caricano la cronologia quando la apri e i resoconti quando li leggi. Le lavorazioni dei dataset aggiornano lo stato senza ricaricare tutta la pagina. [Ticket](/member/tickets)

## [0.146.1] - 2026-09-06

### Fixed

- **I controlli automatici periodici non possono più fermarsi in silenzio.** Se uno di essi finisce su una corsia di lavorazione che nessuno segue, adesso te ne accorgi subito: prima poteva restare fermo per settimane senza un solo segnale.

## [0.146.0] - 2026-09-06

### Added

- **Domande sui ticket**: le domande hanno un posto loro, separato dai commenti. Chiedi, rispondi al punto giusto, e segna una domanda come bloccante quando il lavoro non può andare avanti senza risposta. Chi apre il ticket vede subito se sta aspettando. [Ticket](/member/tickets) ([guida](/member/guides/questions))

### Changed

- **I commenti tornano a essere solo conversazione.** Prima un commento scritto dopo una domanda veniva preso per la risposta, anche se parlava d'altro. Ora la risposta appartiene alla domanda a cui risponde.

## [0.145.1] - 2026-09-05

### Changed

- **La pulizia notturna dei dati non appesantisce più il sistema.** I dati di errori, registri, prestazioni, visite e server sono divisi per mese: quando un mese esce dal periodo di conservazione se ne va tutto insieme e lo spazio torna libero subito. Cosa tieni, e per quanto, non cambia.

## [0.144.1] - 2026-09-04

### Added

- **Valore in comune**: quando lo stesso valore riservato è tenuto a mano in più progetti, te lo diciamo e proponiamo di spostarlo una volta sola fra quelli dell'organizzazione. Ogni progetto continua a chiamarlo come lo chiama oggi. Niente si sposta senza la tua conferma. [Da sistemare](/member/vault/attention) ([guida](/member/guides/shared-values))

## [0.143.4] - 2026-09-04

### Fixed

- **Un solo controllo andato storto non fa più partire l'avviso.** Prima bastava una risposta mancata per dichiarare il sito irraggiungibile, e un minuto dopo arrivava il rientro. Ora serve una conferma: due controlli falliti di fila, e quanti ne servono lo scegli tu sulla scheda del sito. [Uptime](/member/monitoring/monitors)
- **Un rallentamento del sistema non fa più sembrare cadute le macchine.** Quando il sistema respinge per un momento i dati che le macchine inviano, non le dichiara più giù e non manda «Dati fermi»: avvisa che i dati sono stati respinti. Una macchina che si ferma davvero continua ad avvisare. [Server](/member/monitoring/servers)
- **Pubblicare una versione non manda più avvisi «Contenitore caduto» falsi.** Quando esce una versione nuova, quella vecchia viene spenta di proposito: prima ogni pubblicazione avvisava per ogni parte di ogni macchina, e i guasti veri finivano sepolti. Ora avvisa solo se nessuna versione riparte, e quando riparte annuncia il rientro. [Server](/member/monitoring/servers)

## [0.143.3] - 2026-09-04

### Fixed

- **Una pagina di conoscenza con soli avvisi passa il revisore.** Quando il modello segnalava solo dettagli di forma, la pagina veniva comunque rifiutata; ora entra, e gli avvisi restano visibili. [Conoscenza](/member/knowledge/pages)

## [0.143.2] - 2026-09-04

### Fixed

- **La scheda salute non dà più la posta per morta quando funziona.** La chiave che spedisce non può leggere i domini, e quel rifiuto veniva letto come guasto. Ora fra «spedisce» e «non spedisce» c'è «non lo so». [Salute](/valhalla/health)

## [0.143.1] - 2026-09-04

### Fixed

- **Il revisore delle pagine di conoscenza non boccia più per la forma del titolo.** Le regole di forma le controlla il programma prima del modello; il modello giudica solo il contenuto. Una data di osservazione o il codice di un ticket non contano più come «stato temporaneo». [Conoscenza](/member/knowledge/pages)

## [0.143.0] - 2026-09-04

### Changed

- **Le pagine di conoscenza già esistenti vengono giudicate nel contenuto, non nella forma.** Il controllo sul parco ignora la riga del formato e le etichette mancanti, chiede al revisore se il contenuto vale, e alle pagine promosse aggiunge da solo formato ed etichette. [Conoscenza](/member/knowledge/pages)

## [0.142.2] - 2026-09-03

### Added

- **Le pagine di conoscenza si rileggono**: decisioni e guide ricevono una data entro cui vanno riguardate. Passata quella data restano cercabili, ma segnate come da rivedere, e compaiono nella pagina Revisione, dove puoi confermare che sono ancora vere. [Conoscenza](/member/knowledge/pages)

### Fixed

- **L'elenco dei database mostra sempre lo stesso risultato.** Quando un server principale dichiarava una replica sola ma ne esistevano due uguali, quale delle due venisse unita alla riga del principale cambiava da una volta all'altra. Ora l'accorpamento segue un ordine fisso. [Server](/member/monitoring/servers)

## [0.142.0] - 2026-09-03

### Changed

- **Il parere dell'AI non basta più.** Prima il giudizio dell'intelligenza artificiale mandava un ticket direttamente in lavorazione automatica. Ora quel giudizio resta un consiglio scritto nella scheda del ticket: nessun agente parte finché non lo consenti tu. [Ticket](/member/tickets)

## [0.141.1] - 2026-09-03

### Fixed

- **L'intelligenza artificiale risponde davvero.** Nella versione precedente il collegamento al server AI era annunciato ma la sua chiave non arrivava fino al prodotto, e assistente, bozze e smistamento restavano in silenzio. Ora funzionano.

## [0.141.0] - 2026-09-03

### Changed

- **L'intelligenza artificiale è inclusa.** Assistente, smistamento, bozze dei ticket, doppioni e risposte alle domande arrivano dal server AI di CloseYourIt: non serve più collegare una chiave Google. Le risposte lunghe possono richiedere qualche minuto. [Assistente](/member/assistant/conversations)

## [0.140.0] - 2026-09-03

### Added

- **Controllo automatico delle pagine di conoscenza**: ogni pagina nuova o modificata viene letta da un revisore che riconosce il formato, verifica che ci sia tutto e che non contenga dati riservati. Se non passa, ti dice cosa correggere prima di salvarla. [Conoscenza](/member/knowledge/pages)
- **Registro attività**: un posto solo per sapere chi ha fatto cosa e quando. Lavoro, ticket, permessi e Vault in un elenco unico, con filtri per persona, azione e periodo. I cambi di permesso, che prima non si leggevano da nessuna parte, ora si vedono qui. [Registro attività](/member/activity) ([guida](/member/guides/activity))

### Changed

- **Cosa fa davvero ogni libreria**: la presentazione delle librerie da collegare alle tue app non promette più che il pacchetto per mobile faccia le stesse cose di quello per Ruby. Ora dice cosa copre e cosa no, così scegli sapendo.
- **I dati di controllo si registrano più in fretta**: errori, log, misure e campioni dei server facevano un lavoro doppio a ogni riga archiviata. Ora quel lavoro inutile non c'è più: sotto carico i dati entrano prima, e le pagine che li leggono restano veloci come erano. [Errori](/member/monitoring/error) · [Log](/member/monitoring/logs)
- **Le occorrenze di un rallentamento si sfogliano da tastiera**: nella scheda di un rallentamento le frecce e i tasti j/k passano da un'occorrenza all'altra, come già si faceva sugli errori. La scorciatoia era annunciata nell'aiuto della pagina ma non rispondeva. [Prestazioni](/member/monitoring/performance)

### Fixed

- **Alcune pagine si aprono più in fretta**: idee, notifiche, scheda di un sito e creazione di un controllo chiedevano un dato in più per ogni riga mostrata. Ora lo chiedono una volta sola per l'intera pagina. [Idee](/member/ideas) · [Notifiche](/member/alerting/notifications) · [Siti](/member/monitoring/sites)
- **Elenco degli errori più veloce per i programmi collegati**: chiesto da un programma collegato ci metteva più tempo che dal terminale, pur mostrando le stesse cose. Ora le due strade fanno lo stesso lavoro e rispondono nello stesso tempo. [Errori](/member/monitoring/error)
- **Gli aggiornamenti non vanno online se il database non risponde**: prima bastava che il programma si avviasse perché la versione nuova prendesse il posto di quella funzionante, anche quando non riusciva a leggere nulla. Ora in quel caso l'aggiornamento si ferma.

## [0.139.2] - 2026-09-03

### Fixed

- **La coda degli agenti non si ferma più dopo un'approvazione.** Da ieri sera, appena una consegna veniva approvata, le macchine non riuscivano più a prendere in carico i ticket di quel progetto. Ora la presa in carico funziona di nuovo.

## [0.139.1] - 2026-09-02

### Added

- **Il README segnala che il repository è lavorato anche da agenti automatici**, con il rimando al flusso documentato in closeyourit-docs.

### Fixed

- **La fase di rilascio riceve il commit approvato.** Il numero che una persona ha approvato viaggia ora insieme al lavoro verso la macchina che rilascia; prima doveva ricavarlo dal ramo, che nel frattempo può essere cambiato, e a volte si fermava senza.

## [0.139.0] - 2026-09-02

### Changed

- **La ricerca intelligente passa da un server con scheda grafica.** Ricerca dei ticket simili, doppioni, pagine correlate e risposte alle domande usano lo stesso modello di prima, ma ora risponde in meno di un secondo invece di decine di secondi. Niente da rifare: quanto già calcolato resta valido.

### Added

- **I codici di accesso dei progetti possono scadere**: quando ne crei uno, scegli una data di scadenza. Passata quella data il codice smette di funzionare, e due settimane prima arriva un avviso a chi può sostituirlo. Lasciando vuota la data, il codice resta valido come prima.
- **Uso di un progetto**: la scheda di ogni progetto ha una pagina nuova che mostra quali sue funzioni e quali pagine vengono aperte davvero, quante volte e quando l'ultima volta. Serve a decidere cosa migliorare e cosa non usa più nessuno. [Progetti](/member/projects)
- **Avviso quando l'intelligenza artificiale smette di rispondere**: se il servizio non risponde o la chiave non vale più, entro un quarto d'ora arriva un avviso a chi amministra. Prima assistente, smistamento automatico e ricerca dei doppioni si spegnevano in silenzio. [Servizi collegati](/member/integrations)

### Security

- **Dati personali nascosti anche nei log e nei dati dei server**: password, codici di accesso e indirizzi email scritti dentro un messaggio vengono sostituiti da un segnaposto, come già succedeva per gli errori. Il resto della riga resta leggibile. [Log](/member/monitoring/logs)
- **Le azioni pericolose chiedono conferma**: eliminare qualcosa, revocare un accesso, dare o togliere poteri, cambiare le impostazioni dell'organizzazione ora si fermano su una domanda prima di partire. Vale anche dal terminale, e ogni conferma resta scritta. [Guida ai permessi](/member/guides/permissions)
- **Vedere un segreto e cambiarlo sono due permessi diversi**: chi può solo vederli ha ora il comando per mostrare il valore; chi può solo cambiarli non lo legge più in chiaro. Chi ha il ruolo Manutentore continua a vedere i valori come prima. [Vault](/member/vault)
- **Il secondo passaggio serve anche per entrare nei panni di un altro utente**: chi amministra deve inserire il codice della sua app di autenticazione prima di aprire il prodotto con l'identità di qualcun altro. Dopo alcuni tentativi sbagliati la sessione si chiude e bisogna rientrare.
- **I codici di accesso al terminale scadono dopo 90 giorni**: quando ne ottieni uno nuovo, vale tre mesi, poi il terminale ti chiede di rientrare. Prima valeva per sempre. Vedi la scadenza di ognuno nei tuoi codici. Le utenze dei programmi restano senza scadenza. [Codici del terminale](/account/cli/tokens)
- **Il browser blocca gli script non autorizzati.** Nell'area riservata il browser impedisce l'esecuzione di codice che non arriva da noi, invece di limitarsi a segnalarlo. Il codice che autorizza i nostri script cambia a ogni pagina, così non si può riutilizzare.

### Fixed

- **Errori dal terminale sempre leggibili.** Se una richiesta partiva con dati rovinati o incompleti, il terminale riceveva una pagina web al posto del messaggio d'errore e non sapeva cosa dire. Ora l'errore arriva sempre nella stessa forma, la stessa che usano i programmi collegati.
- **I controlli automatici partono in orario.** I controlli che girano ogni minuto non aspettano più la fine dei lavori lunghi, come l'addestramento dell'intelligenza artificiale: prima uno di quelli poteva tenerli fermi per un'ora.
- **I guasti si vedono subito**: un lavoro dietro le quinte che fallisce per un difetto viene segnalato al primo colpo, invece di essere ripetuto altre due volte per lo stesso esito. I tentativi in più restano dove servono davvero: rete lenta o servizio esterno momentaneamente giù.
- **Messaggi storti dal bot e da GitHub**: un messaggio arrivato incompleto o nella forma sbagliata viene lasciato cadere, invece di bloccare il bot Telegram o il collegamento con GitHub. Al bot arrivano solo i campi che servono davvero.
- **La sospensione di un'organizzazione ha effetto davvero**: quando un'organizzazione viene sospesa, chi ne fa parte non entra più e legge sullo schermo il motivo. Vale anche per i programmi collegati e per il terminale, che smettono di inviare e leggere dati. Chi ha anche un'altra organizzazione continua a lavorare lì.
- **Nessun buco nei dati dei server**: un conteggio fuori scala mandato da una macchina non fa più perdere tutta la rilevazione di quel minuto. Il numero implausibile viene riportato al massimo consentito e il resto della fotografia arriva intero. [Server](/member/monitoring/servers)
- **Righe per pagina anche nelle liste dei database**: la scelta di quante righe mostrare c'era nella barra ma non faceva niente. Ora funziona come nelle altre liste del prodotto. [Database](/member/monitoring/databases)
- **I log con l'orario nel testo si raggruppano**: righe identiche che cambiavano solo per l'ora scritta dentro il messaggio restavano una per una. Ora finiscono in un gruppo unico, e il conteggio dice quanti problemi diversi ci sono davvero. [Log](/member/monitoring/logs)

## [0.138.3] - 2026-09-02

### Fixed

- **Dopo la lavorazione il sistema parla davvero con GitHub.** Il controllo della proposta, l'assegnazione della versione, la verifica su staging e la prova del rilascio usavano un identificativo sbagliato e GitHub rispondeva sempre «non trovato». Ora il flusso può proseguire fino al rilascio.

## [0.138.2] - 2026-09-02

### Fixed

- **«Sblocca e riprova» rimette davvero in controllo la proposta.** Dopo un blocco sul controllo della proposta, lo sblocco fa ripartire la verifica invece di lasciare la scheda ferma su «va avanti da sola». Il motivo del blocco ora riporta anche la risposta di GitHub.

## [0.138.1] - 2026-09-02

### Fixed

- **Il lavoro già consegnato non viene più respinto.** Quando una macchina ritrova la proposta già aperta da un tentativo precedente, o si ferma senza toccare niente, la consegna ora passa e arriva alla tua approvazione. Prima si bloccava dopo due giri con un motivo sbagliato.

## [0.138.0] - 2026-09-01

### Added

- **Scheda di un server più completa**: la pagina di una macchina mostra ora la scheda grafica, tutti i sensori di temperatura, il carico dei singoli processori, la memoria di scambio e il traffico di ogni rete. Prima si vedevano solo quattro numeri. [Server](/member/monitoring/servers)

## [0.137.0] - 2026-09-01

### Added

- **Informativa privacy.** Il sito e l'area riservata ora linkano una pagina che spiega quali dati vengono raccolti e perché, in italiano e in inglese. Anche il modulo di richiesta accesso vi rimanda.
- **Il prodotto sa quali sue parti vengono usate.** L'area riservata registra in forma anonima quali pagine vengono aperte — mai chi, cosa scrive o da dove — per capire quali funzioni contano davvero.

### Changed

- **Le schede da approvare si leggono in un colpo d'occhio.** Nella coda ogni scheda mostra l'essenziale per decidere: cosa cambia, i rischi e il motivo di un eventuale no. Il documento completo resta nella scheda a tutta pagina e nel file scaricabile. [Home](/member/home)

### Fixed

- **Un lavoro programmato che fallisce non resta più verde.** Lo stato del monitor segue l'esito dell'ultima esecuzione: un fallimento si vede e può far partire un avviso.
- **Condividere le statistiche in pubblico richiede il permesso giusto.** L'attivazione della pagina pubblica delle analitiche chiede un permesso dedicato e registra chi l'ha fatta.
- **Cancellare un ruolo o un team chiede conferma.** Prima di procedere viene detto chi resterebbe senza permessi.

## [0.136.2] - 2026-08-31

### Changed

- **I filtri degli elenchi ora si ricordano.** Filtra i ticket, apri una scheda e torna indietro: ritrovi l'elenco filtrato com'era, da qualunque strada ci arrivi. Vale per tutte le pagine con la barra dei filtri, e «Azzera filtri» li fa dimenticare davvero. [Ticket](/member/tickets)

## [0.135.1] - 2026-08-31

### Changed

- **Le colonne del lavoro concluso si aprono da sole quando c'è qualcosa da leggere.** Su bacheca e roadmap, se non hai mai personalizzato le colonne, Risolti e Chiusi arrivano aperti quando contengono lavoro recente e ripiegati quando sono vuoti. [Ticket](/member/tickets)
- **Gli elenchi lunghi si leggono a pagine.** Le attenzioni del vault, le versioni delle pagine e dei file, le conversazioni con l'assistente, i campioni dei dataset e altri elenchi mostrano un primo blocco con i comandi per scorrere, invece di caricare tutto in una volta. [Vault](/member/vault/attention)
- **Colori più leggibili.** Le etichette colorate di stato, le voci del menu laterale e le didascalie più chiare ora rispettano la soglia di leggibilità che il prodotto si è dato: il testo piccolo si distingue meglio dal fondo.
- **Le novità si scorrono meglio.** Le voci lunghe mostrano la prima frase con un «continua» per aprire il resto: trovi la versione che cerchi senza scorrere quindici schermate. [Novità](/member/changelog)

### Fixed

- **Da un elenco filtrato senza risultati ora si esce con un clic.** Quando un filtro non trova niente compare il pulsante per azzerarlo, e la barra dei filtri resta sempre visibile: prima in alcune pagine spariva insieme alle righe. [Gruppi](/member/groups)
- **I titoli delle schede del browser dicono che pagina è.** Ricerca, conversazioni con l'assistente e versioni dei file segreto ora hanno un titolo; un apostrofo che compariva come codice è tornato un apostrofo.
- **La riga in attesa di approvazione dice quale macchina ha proposto il lavoro.** Prima la coda mostrava «nessuno» dove l'elenco delle lavorazioni in corso mostrava il nome; ora le due pagine dicono la stessa cosa, e il caso vuoto dice «non registrato». [Home](/member/home)
- **La roadmap vuota parla semplice a chi guarda.** Chi non può creare obiettivi di rilascio legge una frase chiara su cosa comparirà lì, invece di un'istruzione con parole del mestiere che non poteva eseguire. [Progetti](/member/projects)

## [0.134.2] - 2026-08-30

### Fixed

- **Un lavoro che la macchina non può ancora scrivere non viene più consumato a vuoto.** Se il progetto non dichiara come si capisce che un suo rilascio è riuscito, la lavorazione restava in coda, veniva presa in carico e moriva senza far niente, finché non si bloccava. Ora aspetta, e la scheda dice cosa manca. [Ticket](/member/tickets)

## [0.134.1] - 2026-08-30

### Fixed

- **Le lavorazioni automatiche non si fermano più appena un piano viene approvato.** Da quel momento la coda di quel progetto smetteva di consegnare lavoro, e le macchine restavano ferme pur essendo accese: si bloccavano proprio i progetti dove il lavoro stava andando avanti.

## [0.134.0] - 2026-08-29

### Changed

- **«Scrivi il ticket per me» conosce meglio il tuo progetto.** La bozza ora parte anche dalla descrizione del progetto, dal suo repository e dalle pagine «fotografia» della knowledge base, così usa i nomi giusti del prodotto invece di scrivere in generico. [Ticket](/member/tickets)

## [0.133.0] - 2026-08-28

### Added

- **Avviso quando lo spazio dati sta per finire.** Non più solo la soglia fissa: se al ritmo di riempimento attuale il disco dei dati si esaurisce entro due settimane, arriva un avviso con la stima dei giorni rimasti. [Server](/member/monitoring/servers)
- **La storia delle macchine dura un anno.** I numeri dettagliati restano per un mese come oggi; prima di eliminarli vengono riassunti ora per ora, così l'andamento di lungo periodo non si perde più. [Server](/member/monitoring/servers)
- **Rivaluta**: su un ticket ancora da pianificare puoi chiedere di rileggere il codice di oggi. Se la cosa è già stata fatta il ticket si chiude con le prove; se serve ancora, il piano si riscrive da capo. [Home](/member/home)
- **L'avviso sui servizi in errore dice quali sono.** Il messaggio ora nomina i servizi caduti, e dalla scheda della macchina puoi escludere quelli rumorosi che falliscono per come sono fatti, senza spegnere l'avviso per tutto il resto. [Server](/member/monitoring/servers)
- **Avviso sugli aggiornamenti di sicurezza.** Quando una macchina monitorata ha aggiornamenti di sicurezza da installare, ora arriva un avviso: prima il numero compariva solo nella pagina dei server. [Server](/member/monitoring/servers)
- **Avviso quando i dati di una macchina restano fermi.** Se un server risponde ma i suoi numeri non si aggiornano da oltre un quarto d'ora, ora lo sai subito: prima la scheda cambiava colore e nessuno veniva avvisato. [Server](/member/monitoring/servers)
- **La pagina del server mostra i processi principali.** Quando processore o memoria sono sotto sforzo, ora vedi subito quali programmi stanno consumando di più, con il loro peso aggiornato a ogni rilevazione. [Server](/member/monitoring/servers)

### Fixed

- **Il piano di una lavorazione si scarica anche dalla pagina delle decisioni.** Prima il file era offerto solo dalla scheda del ticket: chi decideva da lì doveva uscirne per averlo.

- **Gli spazi dati di prova delle lavorazioni finite si liberano da soli.** Una cartella di lavoro rimasta lì li teneva in vita per sempre, e si accumulavano finché qualcuno non faceva pulizia a mano.

## [0.132.6] - 2026-08-28

### Fixed

- **Quando un contenitore torna su, ora lo sai.** L'avviso di rientro esisteva ma sulle organizzazioni già create non aveva una regola: sul pannello la caduta restava l'ultima parola anche a guasto risolto.

## [0.132.5] - 2026-08-28

### Fixed

- **Un ticket lasciato a metà da una macchina non resta bloccato per sempre.** Se la lavorazione si ferma e per un giorno non dà più segno di vita, il ticket torna spostabile senza che serva sbloccarlo a mano uno per uno.

## [0.132.4] - 2026-08-27

### Fixed

- **Il menu laterale risponde anche prima che la pagina abbia finito di caricare.** Su computer si vedeva ma restava insensibile ai clic finché non partiva tutto il codice, e nel pannello di amministrazione non c'era nemmeno il menu in basso come alternativa.

- **Sul telefono non c'è più una fascia vuota sotto le tabelle che ci stanno tutte.** Lo spazio serviva a non far coprire l'ultima riga dall'avviso «scorri», ma restava acceso anche quando quell'avviso non compariva.

- **Il collegamento «vai al contenuto» ora salta davvero, e i grafici non chiedono di scorrere quando ci starebbero.** La larghezza minima del grafico era fissa: con poche barre imponeva uno scorrimento che non serviva.

## [0.132.3] - 2026-08-27

### Fixed

- **Le notifiche non si dichiarano più inviate quando sono soltanto in coda.** Un messaggio Telegram rifiutato e una email mai partita risultavano consegnati: ora lo stato lo scrive la consegna vera, non l'accodamento.

- **Un ticket lavorato da un agente ora si cancella.** La cancellazione falliva sempre, da riga di comando, da API e dalla pagina, e mostrava solo un errore muto: il database rifiutava di togliere il lavoro dell'agente prima dei documenti attaccati.

## [0.132.2] - 2026-08-27

### Fixed

- **Le notifiche via email con un titolo su più righe non partivano più.** L'a capo finiva nell'oggetto e il fornitore rifiutava l'intera spedizione: 3.718 invii persi dal 9 agosto. Ora l'oggetto sta sempre su una riga.

- **Anche le intestazioni scritte a mano dicono ora quale colonna sono.** Centoundici colonne in ventotto elenchi restavano mute: chi usa un lettore di schermo sentiva i valori senza sapere a cosa appartenessero.

## [0.132.1] - 2026-08-27

### Fixed

- **Tutte le tabelle scorrono su schermo stretto, e dicono a voce quale colonna stai leggendo.** Sedici elenchi sfondavano la pagina invece di scorrere; ora scorrono tutti, e ogni intestazione dichiara la propria colonna ai lettori di schermo.

## [0.132.0] - 2026-08-27

### Changed

- **Su telefono menu, tabelle e grafici sono più facili da usare senza cambiare le pagine.** Il menu laterale trattiene il focus finché è aperto e lo restituisce quando si chiude; tabelle, plancia ticket e grafico degli errori segnalano quando c'è altro contenuto a destra. Il pulsante dell'assistente ora sta nella barra superiore mobile e non copre più la navigazione in basso.

- **La schermata iniziale mostra solo quello che aspetta te.** Le domande delle lavorazioni automatiche arrivano a chi deve revisionare il ticket, e non più a chiunque possa vederlo. [Home](/member/home)

- **Il conteggio delle lavorazioni che vanno avanti da sole è di chi ne risponde.** Lo vedi, insieme al loro elenco, solo per i progetti di cui sei il responsabile tecnico. A chi non ne ha nessuno non compare più. [Decisioni](/member/home/approvals)

### Fixed

- **Il confine ambienti sui segreti vale anche nel browser.** Chi è confinato a certi ambienti non scarica più il file segreto né rilegge dallo storico il valore di un ambiente che non gli spetta: il web ora si comporta come il terminale, e il tentativo negato resta nel registro su entrambi i canali. [Ticket](/member/tickets)

## [0.131.0] - 2026-08-25

### Added

- **Le lavorazioni automatiche si possono leggere e verificare senza ricostruirle.** Il piano separa interventi, motivazioni, rischi e scenari; il resoconto mostra file, prove e rilievi. Gli scenari diventano frasi leggibili e lo stesso piano si può scaricare in Markdown. [Ticket](/member/tickets)

### Changed

- **Gli host che lavorano i ticket dichiarano una piattaforma supportata.** Il sistema ammette soltanto Automator Linux compatibili e spiega perché una macchina non può prendere lavoro, invece di lasciarla fallire dopo l’assegnazione.

## [0.130.0] - 2026-08-24

### Removed

- **Via il riquadro «E adesso?» dalla schermata iniziale.** Sotto la decisione la pagina finiva con un riquadro che proponeva dove andare. Non serviva: quelle pagine stanno tutte nel menu, e in fondo a una schermata che mostra una cosa sola era l'unica parte lunga da leggere.

## [0.129.0] - 2026-08-24

### Changed

- **Adesso la schermata iniziale ti mette davanti una cosa sola da decidere.** Prima erano quattro elenchi affiancati e bisognava scegliere da dove cominciare. Adesso vedi una cosa sola, quella ferma da più tempo: decidi e compare la successiva. L'elenco completo resta a un clic. [Decisioni](/member/home/approvals) ([guida](/member/guides/approvals))

- **Puoi rimandare una decisione a domani, o saltarla per adesso.** Se una cosa oggi non la puoi guardare, ora puoi toglierla di mezzo senza deciderla. «Salta» te la rimette in coda subito, «Rimanda a domani» la fa sparire fino a domani mattina, anche da un altro computer. Chi l'ha chiesta continua a vederla in attesa.

- **I riferimenti del progetto stanno sempre nello stesso posto.** Sulla schermata delle decisioni, a sinistra, trovi sigla e nome del progetto, dove sta il codice, quali ambienti ha e i collegamenti alle sue pagine.

## [0.128.0] - 2026-08-24

### Fixed

- **Quando il pacchetto di credenziali non si riesce a costruire, adesso si sa.** Il sistema prepara un pacchetto unico con le credenziali del progetto e lo consegna a GitHub, dove la catena dei rilasci lo legge. Se non riusciva a leggere i file di configurazione del repository non costruiva niente e tirava dritto, come se quel progetto il pacchetto non lo usasse: nessun errore, nessuna traccia, e la sincronizzazione si dichiarava riuscita. Il guasto saltava fuori mesi dopo, al rilascio, che si ferma perché la cassetta di quell'ambiente è vuota. Adesso la sincronizzazione si ferma e la scheda del progetto dice quali file non è riuscita a leggere. Un progetto che quei file non li ha continua a sincronizzare senza avvisi. [Vault](/member/vault)

## [0.127.0] - 2026-08-24

### Changed

- **I filtri delle approvazioni stanno in una riga sola.** Tre file di pulsanti riempivano mezza schermata prima ancora della prima riga da decidere. Adesso sono tre menu a tendina in un'unica barra, come sui ticket, con il numero di richieste in attesa scritto dentro le voci. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

### Fixed

- **Una sincronizzazione dei segreti a metà non si dichiara più riuscita.** Se un ambiente del progetto non era collegato al repository veniva saltato in silenzio, e la sincronizzazione si diceva riuscita lo stesso. Adesso si ferma prima di scrivere, dice quale ambiente manca, e l'esito porta scritto su quali ambienti ha lavorato. [Vault](/member/vault)

## [0.126.0] - 2026-08-23

### Fixed

- **Basta avvisi di server irraggiungibili quando i server stanno benissimo.** Ogni notte, verso le quattro, arrivavano decine di avvisi che davano tutte le macchine per cadute; un minuto dopo erano di nuovo a posto. Adesso il contatto viene segnato appena la macchina si fa sentire. Una macchina davvero spenta resta segnalata entro tre minuti. [Server](/member/monitoring/servers)

- **Il terzo permesso sparisce: dopo il tuo sì al lavoro, il rilascio parte da solo.** Era la terza volta che ti si chiedeva il via libera sullo stesso lavoro, e non decideva niente di nuovo. Adesso, quando la prova sull'ambiente di prova si conclude davvero, il rilascio parte da sé e la card «Rilascio da autorizzare» non compare più.

- **Le spunte verdi finte spariscono, e al loro posto c'è il verbale di quello che il sistema ha guardato.** Accanto a ogni criterio di accettazione compariva una spunta verde anche quando nessuno aveva verificato niente. Adesso sono punti neutri, e sotto il racconto del lavoro un riquadro mostra cosa il sistema ha visto davvero.

- **Quando il sistema non riesce a leggere su GitHub, adesso lo dice.** La lavorazione si fermava e l'elenco continuava a dire «va avanti da sola». Adesso sotto lo stato compare una riga con cosa non riesce a leggere e a che ora riproverà. Su un lavoro che aspetta una tua decisione quella riga non compare.

- **Per i pacchetti, «Fatto» è quello che il magazzino pubblico mostra a chi installa.** Sei progetti pubblicano un pacchetto invece di un sito, e bastava che la pubblicazione finisse senza errori. Adesso il sistema guarda lo scaffale da fuori: la versione dev'esserci, non essere ritirata, ed essere indicata come ultima buona.

- **«Fatto» solo quando il sistema ha visto il rilascio in piedi.** Il ticket diventava «Fatto» appena la macchina diceva di aver messo l'etichetta della versione, quando ancora non era uscito niente. Adesso passa da «In chiusura» e chiude solo se la produzione risponde con quella versione. Resta il pulsante «segna come rilasciato».

- **La coda salta i ticket che aspettano un prerequisito, e la scheda dice quale.** Un ticket in attesa veniva preso lo stesso: piano scritto, codice scritto, e il muro arrivava alla fine. Adesso la coda lo salta e passa al primo lavoro buono, e sulla scheda compare il codice del ticket che lo trattiene.

- **Due ticket messi in fila escono con lo stesso rilascio.** «Va dopo» voleva dire aspettare che il primo fosse vivo in produzione, e ogni dipendenza costava un giro intero di attesa. Adesso basta che il codice del prerequisito sia unito e provato. Per chiudere un ticket a mano la regola severa resta.

- **La guida alle registrazioni dice tutto quello che serve per farle arrivare.** Prometteva che bastasse accendere l'interruttore sul progetto: chi la seguiva alla lettera non vedeva mai una sessione. Adesso la [guida](/member/guides/replays) mostra anche il codice da mettere nelle pagine, già compilato per il progetto che scegli.

- **Le registrazioni delle sessioni ora si vedono.** La pagina di una sessione registrata mostrava un riquadro bianco anche quando la registrazione c'era: il componente che disegna il filmato era arrivato incompleto. Ora il filmato si apre e si può riprodurre, anche dentro il dettaglio di un errore. [Session replay](/member/monitoring/replays)

- **Il numero della versione lo decide il sistema, non la macchina.** La macchina sceglieva da sé quale cifra cambiare, e due lavorazioni dello stesso progetto avviate vicine sceglievano lo stesso numero. Adesso il numero viene assegnato una volta sola quando il lavoro parte, e una consegna con un numero diverso viene rifiutata.

- **Lo staging si conclude quando il sistema vede il codice approvato atterrato.** Prima bastava che la macchina scrivesse «fatto»: se l'ultimo passaggio non riusciva, in produzione poteva finire un codice diverso da quello approvato. Adesso il sistema va a guardare da solo, e se non lo trova dove doveva, chiama te.

### Changed

- **Una porta sola per decidere, e le due liste diventano una.** La stessa decisione si poteva prendere da cinque posti diversi, ognuno con parole e regole sue. Adesso premi da dove vuoi e arrivi sempre nella stessa scheda; un ticket concluso non è decidibile da nessuna parte. In cima trovi due numeri: cosa aspetta te, cosa va avanti da solo. [Approvazioni](/member/home/approvals)

- **La plancia mostra i sei passaggi del modello, non le fasi interne della macchina.** Le colonne portavano i nomi interni della macchina, diversi da quelli con cui la stessa riga diceva a che punto era. Adesso sono le sei parole del modello, le stesse del ticket, e una lavorazione ferma ha un segno rosso dove si è fermata.

### Fixed

- **«Bloccato» solo quando serve davvero una tua decisione, e il numero che leggi è quello vero.** Un guasto passeggero fermava la lavorazione come un errore vero, e il conteggio arrivava a dire «0 volte di fila» proprio dove devi decidere. Adesso si aspetta e si riprova da soli, e il numero è uno solo, calcolato in un punto solo.

### Fixed

- **Se il codice cambia dopo il controllo, l'approvazione non passa.** Chiunque poteva mettere altro codice nella proposta dopo il controllo, e al tuo sì nessuno ricontrollava niente. Adesso, nell'istante del sì, il sistema riguarda cosa c'è dentro: se è cambiato non passa, te lo dice, ricontrolla da solo e torna da te.

### Added

- **La scheda di revisione mostra il codice esatto su cui stai dicendo di sì.** Prima davanti avevi solo il piano e il racconto di chi aveva lavorato: per vedere il codice dovevi uscire dalla pagina. Adesso in cima c'è una riga con l'archivio, la proposta, la versione esatta controllata e l'esito dei controlli.

### Changed

- **«Sto controllando la proposta» adesso ha un nome, e non ti chiede niente.** Il momento in cui il sistema legge gli esiti dei controlli si raccontava come «in lavorazione», come se l'agente stesse ancora scrivendo codice. Adesso si chiama «Controllo della proposta» e dice chiaro che va avanti da solo.

### Added

- **Il sistema apre la proposta, legge i controlli su quel codice, e solo allora te la mette davanti.** Prima il lavoro arrivava fra le cose da revisionare sulla parola della stessa macchina che l'aveva fatto. Adesso ci arriva dopo che il sistema ha aperto la proposta e letto l'esito dei controlli. Il prezzo: qualche minuto in più.

### Fixed

- **Quando l'unione del codice non chiude il ticket, la scheda dice perché.** Il rifiuto si vedeva già, ma senza il motivo. Ora accanto al tentativo resta scritto perché. Anche il caso che restava muto — l'organizzazione non ha uno stato «Fatto» attivo — lascia la sua riga invece di sembrare una chiusura riuscita.

### Changed

- **La consegna prende nota della proposta e smette di portare il lavoro davanti a te.** Il lavoro entrava nella tua lista appena la macchina diceva «ho finito», senza che nessuno avesse aperto la proposta. Adesso la consegna scrive soltanto dove sta la proposta, e il lavoro ti arriva davanti dopo il controllo del sistema.

### Fixed

- **Il via libera al lavoro finito lo firma una persona, non l'account di servizio di una macchina.** La seconda fermata controllava solo il permesso di modificare i ticket, che ha anche la macchina: poteva firmarsi da sola il via libera. Adesso è chiusa come la prima, e tu continui ad approvare col tuo accesso.

### Changed

- **Mentre una macchina lavora, lo stato del ticket lo sposti solo tu.** La parola sul ticket la poteva spostare chiunque: tu, la macchina dal terminale, e GitHub quando univa il codice. Adesso, finché una lavorazione è aperta, la leva ha un padrone solo: la sposti tu dalla pagina, dopo aver preso in carico il ticket.

### Changed

- **Solo il codice che la macchina ha davvero prodotto arriva davanti a chi approva.** La macchina allegava un indirizzo e il sistema si fidava: poteva puntare a una versione vecchia o a un lavoro a metà, e da fuori erano identici. Adesso dichiara anche l'impronta esatta del codice che ha in mano, e senza quella la consegna viene rifiutata.

### Changed

- **Il vincolo che hai deciso approvando il piano adesso arriva alla macchina che lavora.** Le decisioni fissate dall'approvazione restavano sul server, e la macchina deduceva da sé dove aprire la proposta. Ora viaggiano insieme al piano approvato: se il piano che arriva non è quello approvato, la macchina si ferma.

### Added

- **Approvare un piano adesso fissa dove il lavoro potrà nascere e come si proverà che è finito.** Prima l'approvazione non fissava niente: la prova che dice «fatto» la sceglieva chi esegue, alla fine. Adesso le due cose sono fissate e le leggi in chiaro prima di premere «approva». Se ne manca una, una riga rossa dice quale.

### Fixed

- **Chi rilegge il lavoro della macchina adesso guarda il codice, e dice quale codice ha guardato.** Il secondo assistente riceveva solo il riassunto scritto dal primo: un lavoro sbagliato passava se il riassunto era scritto bene. Adesso apre le modifiche davvero, e il suo giudizio porta l'impronta di ciò che ha letto.

## [0.125.0] - 2026-08-21

### Fixed

- **La seconda firma su una modifica ai segreti la mette una persona, non un automatismo**: un automatismo con i permessi giusti poteva approvare una modifica ai segreti al posto di una persona. Ora approvare e respingere sono riservati alle persone, ovunque si decida. [Da sistemare](/member/vault/attention)

- **«Scrivi il ticket per me» adesso la bozza la scrive davvero**: premendo il pulsante compariva un errore incomprensibile invece della bozza. Ora la bozza arriva sempre, e se qualcosa va storto il prodotto riprova da solo o ti dice come rimediare. [Ticket](/member/tickets)

### Added

- **Far imparare il prodotto e chiedergli una risposta si fa anche da riga di comando**: dal terminale ora avvii l'apprendimento su una raccolta di esempi, ne segui lo stato e chiedi risposte su casi nuovi, foto comprese, con gli stessi permessi e risultati del sito. [Dataset](/member/datasets) ([guida](/member/guides/datasets))

- **Le raccolte di esempi per l'intelligenza artificiale si maneggiano anche da riga di comando**: dal terminale ora crei le raccolte, aggiungi e correggi le righe — foto comprese — e le ritrovi cercandole, con le stesse regole e protezioni del sito. [Dataset](/member/datasets) ([guida](/member/guides/datasets))

- **I documenti di un progetto si maneggiano anche da riga di comando**: dal terminale ora si caricano, cercano, scaricano, rinominano ed eliminano i documenti di progetto, con le stesse protezioni e la stessa cronologia del sito. [Progetti](/member/projects)

- **Vedi da quali dispositivi sei entrato, e ne chiudi uno alla volta**: un elenco mostra gli accessi aperti e puoi chiudere quelli che non riconosci, o tutti tranne quello che stai usando. Cambiare la password ora chiude anche le credenziali della riga di comando. ([Accessi attivi](/account/sessions) · [Token CLI](/account/cli/tokens))

- **Le proposte di conoscenza si accettano e si scartano anche dal terminale, ma a deciderle resta una persona**: la decisione ora si prende anche da riga di comando, con il proprio accesso personale. Un automatismo non può approvare né scartare, nemmeno le pagine che ha scritto lui. ([Proposte in attesa](/member/knowledge/reviews) · [guida](/member/guides/knowledge-review))

- **I file riservati personali e dell'organizzazione si maneggiano da riga di comando come quelli di progetto**: dal terminale ora si rivedono le versioni precedenti, si ripristina quella giusta e si cancella per sempre un file, con le stesse protezioni del sito. L'elenco mostra anche i file messi da parte. [File personali](/member/personal/files) · [File dell'organizzazione](/member/shared/files)

- **La pagina del ticket dice anche quando non c'è niente da segnalare.** Il riquadro rosso delle anomalie di sicurezza non compariva mai, per un difetto. Ora funziona, e quando il controllo è stato fatto senza trovare niente la pagina lo scrive invece di tacere.

- **Una versione risulta viva solo se qualcuno l'ha vista in piedi.** Ogni versione in elenco ora porta il timbro del controllo che l'ha vista rispondere in produzione; le righe nate da una semplice segnalazione di errore restano senza timbro. Per ora non cambia niente di visibile.

- **Il resoconto di un rilascio dice su quale codice esatto è stato messo il numero di versione.** La sigla del codice rilasciato ora è obbligatoria nel resoconto e compare accorciata nella scheda della lavorazione, così si può controllare che sia uscito il codice approvato.

- **Ogni progetto dichiara come si capisce che un suo rilascio è arrivato davvero.** Ora scegli tu, dalla scheda GitHub del progetto, quale prova conta come rilascio riuscito. Per adesso cambia solo la scelta: nessun ticket si muove in modo diverso.

### Changed

- **La riga delle Lavorazioni dice una cosa sola, con le parole del modello.** L'elenco raccontava lo stesso stato due volte, con due vocabolari diversi. Ora ogni riga usa una parola sola, la stessa della scheda del ticket, e il colore continua a dire chi aspetta chi.

## [0.124.1] - 2026-08-21

### Fixed

- **Il numero di persone online non esce più dal suo riquadro**: la scritta con quante persone sono online sbordava dal riquadro in alto. Ora resta dentro; sugli schermi stretti sparisce e il numero si legge aprendo l'elenco.

## [0.124.0] - 2026-08-21

### Added

- **Il sistema annota quale codice c'è dentro una proposta di modifica, e si accorge quando cambia**: a ogni apertura e aggiornamento viene registrato il codice esatto della proposta, con l'ora della comunicazione di GitHub. Non cambia niente di visibile: serve ai controlli futuri.

- **Il sistema sa rileggere una proposta di modifica, e sa dire cosa ha visto**: il server ora apre la proposta da sé e legge codice, ramo, stato ed esito dei controlli, distinguendo «non esiste» da «GitHub non risponde». Niente di nuovo da vedere: serve ai passi successivi.

- **Il link di un invito si copia dalla pagina delle persone**: accanto a ogni invito in attesa c'è «Link», con un pulsante per copiare il collegamento e mandarlo alla persona quando l'email non arriva. Lo vede solo chi può invitare. [Persone](/member/members)

- **La barra porta contesto, azioni e ricerca nello stesso posto**: su computer tutto sta in una sola riga ordinata e la lente apre una ricerca unica tra progetti, ticket, errori e pagine, anche con «⌘K» o «Ctrl+K». Sul telefono le voci principali passano in basso, raccolte anche nel Menu.

- **«Scrivi il ticket per me» ora sa di cosa parla, e si lascia correggere**: la bozza era generica perché ignorava la conoscenza del progetto. Ora prima di scrivere legge fino a due pagine di conoscenza pertinenti, e sotto la bozza dice quali ha letto, o che non ne ha letta nessuna. [Ticket](/member/tickets)

- **La bozza si legge accanto a chi la sta chiedendo, e si corregge a parole**: la finestra ora si divide in due — a sinistra scrivi, a destra leggi — con il progetto da scegliere in cima. Sotto la bozza scrivi cosa non va e viene riscritta tenendo il resto com'era. [Ticket](/member/tickets)

- **Il sistema ha dove annotare quello che vede coi propri occhi**: nascono i campi in cui il sistema registrerà i fatti osservati su una lavorazione — proposta aperta, respinte, prova di rilascio richiesta. Per ora restano vuoti e non cambia niente di visibile. [Approvazioni](/member/home/approvals)

### Changed

- **I ticket simili si spuntano mentre scrivi, e il ticket nasce già collegato**: accanto a ogni ticket simile ora c'è una casella, con scritto quanto si assomigliano: spunti quelli giusti e il ticket nasce già collegato. Il confronto guarda solo il lavoro vivo dello stesso progetto. [Ticket](/member/tickets)

- **Un nome solo per ogni momento di una lavorazione**: lo stesso momento si chiamava in modi diversi da una pagina all'altra. Ora il percorso ha otto nomi fissi, gli stessi ovunque e nelle due lingue; gli stati del ticket configurati da voi restano intoccati.

- **Un passaggio nuovo non arriva più sotto i tuoi occhi senza nome**: quando un momento non aveva un nome tradotto, in pagina usciva la parola interna del programma. Ora se ne accorge chi costruisce il prodotto, prima che arrivi a te.

### Fixed

- **La macchina può dire che non va avanti, e il sistema la sente.** Certe risposte della macchina — «serve il team», «questo non si può fare» — venivano ignorate e la lavorazione restava ferma senza dirlo. Ora vengono registrate e la lavorazione si ferma dichiarando che aspetta una persona.

- **I prerequisiti fra ticket li decide una persona.** Anche un programma automatico poteva aggiungere o togliere i legami «prima questo, poi quello». Ora chi usa una chiave di servizio riceve un rifiuto esplicito; le persone continuano come prima.

- **La riga di comando smette di avvisare sulla posta quando non serve.** Prima stampava un avviso fisso anche quando la posta era configurata benissimo. Ora, creando o rimandando un invito, dice se le mail vengono davvero consegnate.

- **Un indirizzo di proposta che GitHub non potrebbe aver prodotto non viene più accettato.** Il controllo sull'indirizzo della proposta era così largo che passavano indirizzi inventati. Ora passa solo la forma che GitHub produce davvero, con la stessa regola usata dalla macchina.

- **Un valore che continua dopo la prima riga non passa più dai controlli di forma.** Il controllo guardava solo la prima riga: un nome di versione giusto seguito da qualunque altra cosa passava. Ora il controllo copre il valore intero.

- **Le mail del prodotto tornano a partire**: per dieci giorni inviti, reimpostazioni della password e avvisi venivano respinti perché partivano da un dominio non più autorizzato. Ora arrivano da `noreply@notifications.closeyour.it` e funziona tutto di nuovo.

- **Chi hai tolto dall'organizzazione lo puoi reinvitare**: un vecchio invito invisibile teneva occupata l'email per sempre e bloccava il nuovo. Ora togliendo una persona spariscono anche i suoi inviti, e il divieto vale solo finché un invito è davvero in attesa. [Persone](/member/members)

- **Nessuna password da scegliere se l'account ce l'hai già**: chi apriva l'invito con un indirizzo già registrato sceglieva una password che non veniva mai salvata. Ora l'invito lo dice prima e ti porta all'accesso con la password di sempre.

- **Un rilascio in produzione alla volta, per ogni progetto**: due rilasci dello stesso progetto potevano finire in ordine sbagliato, lasciando in produzione una versione vecchia. Ora finché un rilascio è in corso il successivo aspetta, e la scheda del ticket dice quale sta aspettando.


- **Un lavoro non si chiude più mentre un suo prerequisito è ancora aperto**: il controllo sui prerequisiti non scattava quando a muovere il ticket era la macchina. Ora vale anche lì; il lavoro consegnato resta registrato e il ticket riprende da solo quando il prerequisito si chiude.

## [0.123.0] - 2026-08-17

### Changed

- **La lavorazione automatica di un ticket si legge in tre righe, e un problema di sicurezza si vede subito**: in cima alla scheda ora c'è una sintesi di tre righe con i pulsanti per decidere, i tentativi uguali sono raggruppati e una segnalazione di sicurezza diventa un avviso rosso in cima al ticket. [Ticket](/member/tickets)

- **Chi rimanda indietro un lavoro può spiegarsi per esteso**: la motivazione si fermava a 240 caratteri e il resto andava perso. Ora si scrive quanto serve: le motivazioni lunghe finiscono nel resoconto di lavorazione del ticket, con una riga nella discussione che dice dov'è. [Ticket](/member/tickets) · [Approvazioni](/member/home/approvals)

## [0.122.0] - 2026-08-17

### Changed

- **L'assistente che scrive e analizza i ticket non si spegne più da solo**: queste funzioni giravano su un servizio a credito che, esaurito, le spegneva tutte insieme. Ora usano lo stesso assistente delle altre funzioni; chi ha già collegato la chiave non deve fare niente. [Ticket](/member/tickets) · [Errori](/member/monitoring/error) · [Integrazioni](/member/integrations)

## [0.121.0] - 2026-08-17

### Added
- **Ogni lavorazione ha la sua pagina, e mostra le cose giuste per il punto in cui si trova**: da ogni decisione ora si apre una pagina intera, con il percorso dei passaggi in cima e i pulsanti sempre a portata. Il contenuto cambia col passaggio: piano, lavoro consegnato o motivo del blocco. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

## [0.120.0] - 2026-08-17

### Added

- **La scheda di un sito si legge anche da riga di comando**: dal terminale ora si chiede la scheda di un sito e si leggono configurazione, rilievi aperti, esito dell'ultimo controllo e misure di velocità — gli stessi numeri della pagina. [Siti SEO](/member/monitoring/sites)

### Changed

- **Il codice da incollare nel sito dice quale versione usare**: prima chiedeva sempre «l'ultima versione», così ogni nostra pubblicazione cambiava qualcosa sui siti altrui. Ora il codice si aggancia a una versione precisa e un cambiamento arriva solo quando lo decidi tu ricopiandolo; il codice vecchio continua a funzionare. [Statistiche del sito](/member/monitoring/analytics) ([guida](/member/guides/analytics))

## [0.119.0] - 2026-08-17

### Added

- **Le chiavi dei servizi esterni vengono riprovate ogni giorno**: una chiave revocata o scaduta si scopriva solo quando una funzione smetteva di rispondere. Ora ogni chiave viene riprovata una volta al giorno e l'esito resta scritto accanto a lei, col motivo quando non funziona.

- **Una pagina per collegare i servizi esterni con le tue chiavi**: «Integrazioni», nell'Amministrazione, elenca i servizi collegabili: chi amministra incolla la chiave e il sistema la prova subito con una richiesta vera, rifiutandola se non funziona. Una chiave salvata non si rilegge più: si può solo sostituire. [Integrazioni](/member/integrations) ([guida](/member/guides/integrations))

- **Una pagina mostra tutto quello che gli agenti stanno facendo**: «Lavorazioni» elenca ogni lavoro in corso su tutti i progetti e le macchine, con passaggi fatti, tempi e ultima attività. Tre numeri in cima separano ciò che aspetta una persona da ciò che va avanti da sé. [Lavorazioni](/member/workflows) ([guida](/member/guides/workflows))

### Changed

- **L'assistente e le domande sui ticket usano la chiave della tua organizzazione**: chat, domande sui ticket e sulla conoscenza e riassunti ora partono con la chiave della tua organizzazione. Dove la chiave manca la funzione non parte affatto e la pagina dice cosa collegare. [Assistente](/member/assistant/conversations) · [Chiedi ai ticket](/member/tickets/ask) · [Chiedi alla conoscenza](/member/knowledge/pages/ask)

- **L'analisi rapida e l'esame dei ticket usano la chiave della tua organizzazione**: analisi delle segnalazioni, scrittura dei ticket, consigli, raggruppamento degli errori e previsioni ora partono con la chiave della tua organizzazione. Senza chiave non partono affatto, e il ticket resta «da valutare» con la spiegazione in pagina. [Ticket](/member/tickets) · [Errori](/member/monitoring/error)

- **Le misure di velocità dei siti usano la chiave della tua organizzazione**: ogni sito viene misurato con la chiave della sua organizzazione: limite e coda sono tuoi e non li dividi con nessuno. Dove la chiave manca i siti non vengono misurati e la scheda lo scrive. [Siti SEO](/member/monitoring/sites)

- **Le Approvazioni diventano un quadro d'insieme**: al posto della coda c'è una tabella con una riga per lavorazione e i suoi cinque passaggi, raggruppate per progetto. Il passaggio acceso è quello che aspetta te, e accanto vedi cosa aspetta e da quanto. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

- **Le registrazioni delle sessioni si trovano cercandole con parole normali**: nel menu il nome «Session replay» ora è seguito dalla parola con cui la funzione si cerca, e dalle statistiche del sito un pulsante porta dritto alle registrazioni del progetto. [Session replay](/member/monitoring/replays) · [Statistiche del sito](/member/monitoring/analytics)

### Fixed

- **La pagina del collegamento con GitHub dice dove ti trovi, e si può uscire**: la pagina non aveva né percorso né voce di menu, e per uscirne serviva il tasto indietro del browser. Ora ha l'intestazione delle altre pagine dell'Amministrazione, la voce «GitHub App» nel menu e due numeri in cima sullo stato del collegamento. [GitHub App](/member/integrations/github) · [Amministrazione](/member/settings)

- **L'assistente si apre già pronto a ricevere la domanda**: il riquadro restava per sempre su un cerchietto che gira e il campo per scrivere non compariva mai. Ora il campo compare subito, e se qualcosa va storto il riquadro lo dice a parole e offre un pulsante per riprovare. [Conversazioni](/member/assistant/conversations)

- **Il menu di un cliente esterno mostra solo i posti dove può trovare qualcosa**: un cliente vedeva decine di voci che aprivano pagine vuote. Ora le aree tecniche gli compaiono solo quando contengono qualcosa del suo progetto; per chi è nel team non cambia niente. [Ticket](/member/tickets) · [Progetti](/member/projects)

## [0.118.0] - 2026-08-17

### Changed

- **La pagina di accesso di una persona si apre su cosa può fare davvero**: la pagina ora si apre su un riepilogo di sola lettura — cosa può fare la persona e da dove le arriva — mentre le modifiche stanno in due schede separate, «Accesso» ed «Eccezioni». [Membri](/member/members)

- **Un progetto appena creato dice da dove si comincia**: finché un progetto non ha ticket né dati, la pagina elenca i primi passi nell'ordine in cui si fanno, e ogni passo sparisce appena l'hai fatto. Il riquadro dei ticket vuoto spiega cos'è un ticket e offre il pulsante per creare il primo. [Progetti](/member/projects)

- **Le pagine con più pulsanti su ogni riga si aprono più leggere**: ogni pulsante di ogni riga portava un modulo invisibile, quasi un megabyte su cinquanta righe. Ora il modulo è uno solo per pagina e il peso segue le righe che vedi. [Da sistemare](/member/vault/attention) · [Revisione](/member/knowledge/reviews)

- **La scheda di una macchina si apre su ciò che serve per decidere**: database, dischi, dettagli, progetti collegati e pulsanti stanno ora in cima; gli elenchi lunghi scorrono dentro il proprio riquadro più in basso, senza allungare la pagina. [Server](/member/monitoring/servers)

### Fixed

- **Il menu dice in quale area ti trovi, anche quando l'hai chiusa**: ad area chiusa la posizione si intuiva solo da un colore appena più chiaro. Ora accanto al nome dell'area c'è un segno visibile anche da chiusa, e il lettore di schermo la annuncia. [Ticket](/member/tickets) · [Vault](/member/vault)

- **Nel menu resta aperta un'area alla volta**: le aree aperte si accumulavano fino a trentasei voci in elenco. Ora aprendo un'area le altre si chiudono da sole, e arrivando su una pagina si apre solo l'area a cui appartiene. [Vault](/member/vault) · [Membri](/member/members)

## [0.117.0] - 2026-08-16

### Fixed

- **Il menu laterale dice quando continua sotto il bordo**: su un portatile molte voci restavano sotto il bordo senza nessun segnale, Vault e Amministrazione compresi. Ora, quando ci sono voci più sotto, il fondo del menu sfuma e mostra una freccia, che sparisce arrivati in fondo. [Vault](/member/vault) · [Membri](/member/members)

- **Cercare dentro i registri di una richiesta non ti porta più su quelli di tutti**: cercare o filtrare buttava via la scelta di guardare una sola richiesta, insieme alle altre impostazioni. Ora tutto resta com'era, e quando guardi una richiesta sola la pagina lo scrive sopra l'elenco, con il modo di toglierlo. [Log](/member/monitoring/logs)

- **Raggruppando i registri si vedono tutti i messaggi, e i filtri restano dove sono**: il raggruppamento mostrava solo i primi cinquanta gruppi e spegneva ricerca, filtri e pagine. Ora i gruppi si sfogliano come l'elenco normale e ricerca, filtri, periodo e viste salvate restano al loro posto. [Log](/member/monitoring/logs)

- **Un messaggio dei registri si apre sul nome dell'errore, non su un titolo alto una schermata**: il titolo era il messaggio intero, anche tremila caratteri. Ora il titolo è la prima riga del messaggio, e il testo completo sta sotto in un riquadro tecnico che scorre da solo. [Log](/member/monitoring/logs)

- **Le istruzioni per chi lavora dicono a quale livello le stai scrivendo**: la spiegazione in cima era una sola per tutti i livelli e il modulo non diceva per chi valesse la regola. Ora ogni livello ha la sua spiegazione, e il modulo scrive se stai scrivendo per l'organizzazione, per il gruppo o per il progetto. [Guidance dell'organizzazione](/member/organization/guidance) ([guida](/member/guides/guidance))

- **In tre punti si leggono le parole, non i nomi interni del programma**: una casella dei progetti, due gruppi di permessi e una colonna dei siti mostravano nomi interni o in inglese. Ora si chiamano «Segnalazione rapida di un problema», «Conoscenza», «Conversazioni» e «Rilievi aperti». [Progetti](/member/projects) · [Ruoli](/member/roles) · [Siti](/member/monitoring/sites)

- **Cercando le parole esatte, la Conoscenza guarda tutta la pagina e non solo il titolo**: la ricerca per parole esatte leggeva soltanto i titoli, e pagine esistenti sembravano mancare. Ora trova le parole ovunque siano scritte: titolo, testo e sezione tecnica. [Conoscenza](/member/knowledge/pages)

- **La roadmap si apre sul piano, non sull'archivio di quello che è già finito**: la pagina caricava quasi cinquecento schede in un colpo, quattro su cinque già concluse. Ora ogni colonna mostra un primo gruppo con «Mostra altre», e le colonne del finito partono chiuse di lato. [Roadmap](/member/tickets/roadmap) · [Ticket](/member/tickets)

- **Un grafico senza niente da mostrare lo dice, invece di disegnare una striscia di barrette**: un periodo senza dati veniva disegnato come una fila di barrette minime, che sembrava traffico bassissimo. Ora il grafico scrive in chiaro che nel periodo non c'è niente, in una riga sola. [Log](/member/monitoring/logs) · [Prestazioni](/member/monitoring/performance) · [Errori](/member/monitoring/error)

- **Stato e priorità si leggono in italiano anche dentro i menu**: i menu offrivano «Open, In Progress, Low, Medium» accanto a righe in italiano. Ora usano le stesse parole del resto della pagina; chi ha scelto l'inglese continua a leggere l'inglese. [Ticket](/member/tickets) · [Progetti](/member/projects) · [Errori](/member/monitoring/error)

## [0.116.0] - 2026-08-16

### Fixed

- **I numeri grandi si leggono all'italiana, e lo stesso numero è scritto sempre uguale**: sopra il migliaio compariva la virgola al posto del punto, e lo stesso conteggio cambiava forma nella stessa schermata. Ora le migliaia usano il punto, i decimali la virgola, e ogni numero è scritto uguale ovunque. [Log](/member/monitoring/logs) · [Errori](/member/monitoring/error) · [Ticket](/member/tickets)

- **Il ticket aperto da un errore non dice più «0 persone» dove la pagina dice «non tracciato»**: l'anteprima scriveva «su 0 persone» quando le persone colpite non vengono contate, facendo sembrare innocuo il problema. Ora scrive «non tracciato», e dove il conteggio c'è resta il numero vero. [Errori](/member/monitoring/error)

- **La sequenza di un errore non si ferma più a metà senza dirlo**: l'elenco dei passaggi si fermava al ventesimo senza dichiarare il taglio. Ora la pagina scrive quanti ne restano e li apre con un click; sotto i venti non compare niente. [Errori](/member/monitoring/error)

- **Nell'elenco delle vulnerabilità il numero in cima non contraddice più le righe**: la testata diceva «Totale: 0» sopra otto righe, perché contava solo le aperte senza dirlo. Ora i conteggi si chiamano «Aperte», «Critiche aperte», «Alte aperte» e «Ignorate». [Vulnerabilità](/member/monitoring/vulnerabilities)

- **Nelle impostazioni di un progetto si capisce cosa aspetta il Salva e cosa no**: il pulsante Salva stava solo in cima a una pagina di tre schermate, e alcuni interruttori si salvavano da soli senza dirlo. Ora il pulsante resta visibile mentre scorri e ogni interruttore dichiara che si applica subito, confermando l'esito. [Progetti](/member/projects)

- **Il grafico di un errore segue i filtri, e non contraddice più la pagina**: il grafico ignorava i filtri e disegnava tutti gli ambienti insieme, contraddicendo l'elenco sotto. Ora conta solo le occorrenze che passano i filtri, e quando non ne passa nessuna lo dice. [Errori](/member/monitoring/error)

- **Le scorciatoie delle Prestazioni portano dove promettono**: «Quelli che costano di più» metteva in cima le operazioni più leggere, e «Visti nelle ultime 24 ore» non cambiava niente. Ora la prima ordina per tempo totale consumato e la seconda, rinominata «Visti più di recente», porta in cima le operazioni viste per ultime. [Prestazioni](/member/monitoring/performance)

- **La coda delle pagine da rivedere si sfoglia**: le proposte stavano tutte su una schermata sola e dopo ogni decisione si ripartiva dall'alto. Ora la coda è divisa in pagine, si cerca per titolo e per progetto, e dopo ogni decisione resti dov'eri. [Revisione](/member/knowledge/reviews)

- **I log tornano a collegarsi fra loro**: il codice della richiesta non veniva riconosciuto se il messaggio non cominciava dritto con esso, e i collegamenti fra log, errori e sequenza non partivano. Ora viene riconosciuto anche dopo una riga vuota o uno spazio, e i log già raccolti vengono ripassati ogni notte. [Log](/member/monitoring/logs) · [Prestazioni](/member/monitoring/performance)

## [0.115.0] - 2026-08-16

### Fixed

- **Prima di approvare un lavoro, vedi cosa è stato fatto**: la scheda mostrava solo cose scritte prima del lavoro, e si approvava sulla fiducia. Ora si apre con il resoconto del lavoro consegnato, dice quando nessuno l'ha scritto, e se non c'è niente da approvare lo scrive al posto dei pulsanti. [Approvazioni](/member/home/approvals) · [Ticket](/member/tickets)

- **Le utenze dei programmi non si confondono più con le persone**: nell'elenco dei membri le utenze dei programmi erano identiche ai colleghi e sommate nel conteggio. Ora hanno un segno tutto loro, i numeri in alto sono due, e una lista di attività si condivide solo con persone. [Membri](/member/members) · [Attività](/member/lists)

- **Quando una ricerca non trova niente, l'elenco non dice più di essere vuoto**: una ricerca senza risultati mostrava il messaggio di chi non ha ancora niente. Ora la pagina dice che è la ricerca a non aver trovato nulla, scrive cosa hai cercato e offre il pulsante per azzerare. [Idee](/member/ideas) · [Ticket](/member/tickets) · [Membri](/member/members) · [Team](/member/teams) · [Ruoli](/member/roles) · [Raccolte](/member/knowledge/books) · [Vulnerabilità](/member/monitoring/vulnerabilities)

- **La ricerca dei ticket risponde subito, e dice quando non ha trovato niente**: la ricerca impiegava anche mezzo minuto e restituiva sempre qualcosa, pure per parole inventate. Ora risponde in pochi secondi, dice quando non c'è niente, e puoi scegliere fra ricerca per significato o per parole esatte. [Ticket](/member/tickets)

- **Sbagliare un indirizzo non ti cambia più la lingua**: un indirizzo sbagliato portava su una pagina d'errore tutta in inglese, menu compreso. Ora quelle pagine restano nella lingua scelta, e accorciando l'indirizzo si torna alla Home invece che su «questa pagina non esiste».

- **Le schede delle vulnerabilità e dei problemi SEO si aprono sempre**: aprire una vulnerabilità, o un problema SEO di gravità media o bassa, mostrava «Qualcosa è andato storto» al posto della scheda. Ora si aprono tutte, con o senza colore di gravità. [Vulnerabilità](/member/monitoring/vulnerabilities) · [SEO](/member/monitoring/seo)

## [0.114.0] - 2026-08-16

### Security

- **Sai chi ha aperto una password, quale e da dove**: ogni apertura ora registra il nome della password, l'ambiente, la persona e da dove è arrivata, con una pagina dedicata e filtrabile. Chi gestisce le password può farsi avvisare sulle aperture di un ambiente scelto o sui tentativi non autorizzati. [Progetti](/member/projects)

## [0.113.0] - 2026-08-16

### Added

- **Valori su misura: un valore diverso per una persona sola**: chi gestisce le password del progetto può assegnarne una a una singola persona, che scaricandole la riceve al posto di quella comune. Ogni assegnazione resta scritta nelle attività, e verso GitHub parte sempre il valore standard. ([guida](/member/guides/secret-overrides)) [Progetti](/member/projects)

### Fixed

- **Sai se le password sono arrivate a GitHub**: se la sincronizzazione verso GitHub si fermava, la pagina restava identica a una riuscita e il guasto si scopriva giorni dopo. Ora la scheda GitHub del progetto dice com'è andata l'ultima sincronizzazione e, in caso di errore, motivo e dove intervenire. [Progetti](/member/projects)

### Security

- **Chi può vedere le password dei programmi, e dove**: il limite per ambiente valeva solo da terminale: dal sito chi leggeva le password le vedeva tutte, produzione compresa. Ora vale anche per le persone e ovunque, e i tentativi vietati vengono fermati e registrati nelle attività. [Membri](/member/members)

- **Nessuno può più prendere il posto di una macchina che stai controllando**: con due dati noti chiunque poteva presentarsi al posto di una macchina e farle perdere il permesso per sempre. Ora il permesso di una macchina attiva non viene mai tolto da fuori: una sostituzione la autorizzi tu dalla sua scheda, con un'ora di tempo. [Server](/member/monitoring/servers)

## [0.112.0] - 2026-08-15

### Added

- **Errori: mettere insieme i doppioni, scrivere com'è andata a finire, fare pulizia**: ora puoi unire le righe che raccontano lo stesso guasto, scrivere alla chiusura cosa lo provocava e come l'hai risolto, ed eliminare del tutto un errore che non serve più. [Errori](/member/monitoring/error)

- **L'assistente si usa anche fuori dal sito**: ora apri una conversazione anche fuori dal browser, fai una domanda e leggi la risposta, che dice pure dove è andata a guardare. Vale anche per il «chiedi ai ticket». [Assistente](/member/assistant/conversations)

### Fixed

- **L'assistente di aiuto risponde anche quando il motore principale è occupato**: quando il motore di intelligenza artificiale era pieno, l'assistente non rispondeva affatto. Ora un secondo motore di riserva scrive la risposta, e lo stato del primo si legge nella pagina di salute del sistema. [Assistente](/member/assistant/conversations)

## [0.111.0] - 2026-08-15

### Added

- **Le idee simili si vedono prima di proporne una nuova**: mentre scrivi il titolo compaiono le idee già proposte che dicono la stessa cosa, così apri e voti quella esistente invece di creare un doppione. La ricerca nell'elenco ora capisce anche il significato, non solo le parole esatte. [Idee](/member/ideas)

- **Come sta andando, in un'email**: puoi farti mandare un riepilogo periodico con visite, errori e disponibilità dei tuoi progetti — ogni giorno, ogni lunedì o il primo del mese. Se nel periodo non è successo niente, non parte. ([guida](/member/guides/reports)) [Preferenze delle notifiche](/member/preferences/notifications)

### Security

- **Il lasciapassare per GitHub resta sotto chiave**: il permesso temporaneo usato per lavorare sui progetti GitHub era conservato in chiaro; ora è cifrato come le altre credenziali, o non viene conservato affatto. Per te non cambia niente. [Progetti](/member/projects)

### Fixed

- **Se le lavorazioni in sottofondo si fermano, adesso qualcuno se ne accorge**: quando il motore dei lavori in sottofondo si fermava, nessuno se ne accorgeva e le pagine mostravano dati vecchi. Ora una sentinella esterna lo controlla ogni pochi minuti e apre un avviso, che si chiude da solo quando tutto riparte.

- **Le email tornano a partire**: le email non arrivavano perché l'indirizzo del mittente apparteneva a un dominio non più abilitato a spedire. Ora si spedisce da un dominio valido, con un controllo che ogni giorno verifica che lo resti.

## [0.110.0] - 2026-08-15

### Added

- **I dati inviati dal browser si accettano solo dai siti che dici tu**: nelle impostazioni del progetto puoi elencare i siti da cui accettare misure ed errori dal browser; gli altri vengono rifiutati. Se lasci il campo vuoto non cambia niente. [Progetti](/member/projects)

- **La scheda di un sito dice quanto è veloce, da telefono e da computer**: la scheda ha una nuova linguetta «Prestazioni» con i tempi reali vissuti dai visitatori e un giro di prova che spiega perché il sito è lento. Ogni numero dice se è buono, da migliorare o scarso. [Siti](/member/monitoring/sites)

- **Ogni sito ha la sua scheda**: premendo un sito nell'elenco ora si apre la sua scheda: problemi aperti, pagine viste, impostazioni del controllo e storia degli ultimi giri. Da lì si fa ripartire un controllo o si apre il sito vero. [Siti](/member/monitoring/sites)

### Changed

- **SEO e statistiche del sito stanno finalmente nello stesso posto**: nel menu sono ora un'area unica, «SEO», con i siti controllati, i problemi trovati, le pagine e le statistiche di visita. Gli indirizzi salvati continuano a funzionare. [Siti](/member/monitoring/sites) · [Statistiche del sito](/member/monitoring/analytics)

### Fixed

- **Un'organizzazione creata dal pannello nasce già coi ruoli pronti**: le organizzazioni create dal pannello partivano senza i quattro ruoli da assegnare, e il titolare non aveva niente da dare agli invitati. Ora ci sono fin dal primo giorno. [Ruoli](/member/roles)

### Security

- **Non ci si iscrive più da soli**: la pagina di iscrizione libera permetteva a chiunque di crearsi un accesso e un'organizzazione; ora non esiste più. Si entra solo con un invito o con un accesso creato dal pannello di amministrazione.

## [0.109.0] - 2026-08-15

### Added

- **La rilettura di un lavoro pesa quanto il lavoro che rilegge**: i passaggi che non toccano il codice ricevono ora una verifica leggera sui dati, mentre dove il codice cambia resta la lettura piena. A decidere quale serve è il sistema, non la macchina che ha lavorato. [Automazione](/member/automation)

- **Il passaggio in produzione aspetta il tuo via libera**: il rilascio in produzione non parte più da solo: la lavorazione si ferma e ti chiede l'approvazione, una per volta. E se un tentativo fallisce sempre allo stesso punto, chiama una persona invece di riprovare all'infinito. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

## [0.108.0] - 2026-08-15

### Changed

- **Il periodo di tempo si sceglie allo stesso modo su errori, prestazioni e log**: le tre pagine hanno ora lo stesso selettore del periodo, con le stesse scelte rapide, e il periodo scelto ti segue fra le pagine e finisce nell'indirizzo. Si parte dalle ultime ventiquattro ore. [Errori](/member/monitoring/error) · [Prestazioni](/member/monitoring/performance) · [Log](/member/monitoring/logs)

### Added

- **I server avvisano prima di fermarsi, e dicono quale disco o quale programma è il colpevole**: arriva un avviso quando il database finisce i posti, un disco si riempie o esaurisce i file, la copia di sicurezza si scollega o un programma si riavvia in continuazione — e un secondo avviso quando rientra. I limiti si regolano dalle regole di avviso. [Server](/member/monitoring/servers) ([guida](/member/guides/servers))

- **Le prestazioni dicono se stanno peggiorando, e da che valore in su un numero è rosso**: la scheda di un rallentamento ha ora il grafico «Durata nel tempo» e il confronto col periodo precedente. Passando sopra un tempo si leggono le soglie che decidono il colore, modificabili progetto per progetto. [Prestazioni](/member/monitoring/performance) ([guida](/member/guides/performance))

- **L'Amministrazione spiega cosa sono le cose, invece di darle per note**: ogni voce dell'area porta ora una riga che dice a cosa serve, e Piattaforme e Ambienti spiegano cosa sono anche a elenco vuoto. Una guida nuova mette in fila organizzazione, gruppi, progetti, ambienti e piattaforme. [Piattaforme](/member/platforms) · [Ambienti](/member/environments) ([guida](/member/guides/structure))

- **Le registrazioni delle sessioni si trovano, e si accendono con un interruttore**: la pagina delle sessioni registrate ora sta nel menu, e da lì si arriva all'interruttore per accenderle nelle impostazioni del progetto e a una guida nuova. Prima ci si arrivava solo scrivendo l'indirizzo a mano. [Session replay](/member/monitoring/replays) ([guida](/member/guides/replays))

## [0.107.0] - 2026-08-15

### Added

- **SEO: scopri se il tuo sito si fa trovare, e cosa lo tiene fuori**: dichiari l'indirizzo di un sito e il sistema lo visita come un motore di ricerca, aprendo un rilievo con la prova per ogni problema — titoli mancanti o doppi, pagine non indicizzabili, rimbalzi. Quando il problema sparisce il rilievo si chiude da solo. [SEO](/member/monitoring/seo) ([guida](/member/guides/seo))

- **In cima ai ticket c'è scritto quante decisioni aspettano te**: nella bacheca e nell'elenco c'è ora il conteggio «Aspettano te» con le revisioni in sospeso di cui sei revisore; un clic mostra solo quelle. Si può anche filtrare i ticket per revisore. [Ticket](/member/tickets)

### Changed

- **Le lavorazioni che riprovano da sole escono dalla coda delle decisioni**: le lavorazioni che stanno già riprovando da sole non vengono più contate fra le cose da decidere: stanno in un elenco a parte, dietro il pulsante «In corso, non serve te». Da lì puoi chiudere quella che si è impiantata. ([guida](/member/guides/approvals))

- **Il voto sulle idee dice a cosa serve, e la bacheca mette in cima quelle che si sono mosse**: l'idea ha ora un riquadro «Interesse» con il pulsante per votare, cosa fa il voto e chi ha già votato. La bacheca ordina per ultimo movimento, dichiarato sopra l'elenco. [Idee](/member/ideas)

- **I gruppi di progetti si chiamano gruppi ovunque, e la loro pagina dice come sta il prodotto**: la parola è ora una sola — gruppo — in tutto il prodotto. La pagina di un gruppo mostra errori aperti, ticket non chiusi, disponibilità e ultimo rilascio dell'insieme, coi numeri di ogni progetto. [Gruppi](/member/groups)

- **Chi apre una lavorazione respinta legge cosa è andato storto**: il dettaglio mostra ora l'ultimo tentativo respinto — su quale passo, con quale macchina, quanto è durato — e la motivazione della revisione. Quando qualcosa manca, lo dice invece di lasciare il posto vuoto. [Approvazioni](/member/home/approvals)

### Fixed

- **Le pagine scritte da un assistente non risultano più firmate da una persona**: le pagine proposte da un assistente comparivano col nome della persona di cui usava l'accesso. Ora ogni pagina dice chi l'ha scritta e con l'accesso di chi, finché una persona non ne riscrive davvero il testo. [Conoscenza](/member/knowledge/pages) ([guida](/member/guides/knowledge-review))

## [0.106.0] - 2026-08-15

### Changed

- **Condividere le statistiche del sito si fa dall'alto, accanto alla scelta del periodo**: il comando per creare il collegamento pubblico stava in fondo alla pagina e quasi nessuno lo trovava; ora è in cima, accanto ai pulsanti del periodo. In fondo resta il collegamento già creato, col codice da incorporare e il comando per toglierlo. [Statistiche del sito](/member/monitoring/analytics)

- **La colonna accanto a una pagina di conoscenza parla a chi legge**: la colonna di destra ora dice se l'assistente può già usare la pagina per rispondere, invece di stato in gergo e codici. Cancellare è sceso in un menu con conferma, lontano da «Modifica». [Conoscenza](/member/knowledge/pages)

- **Le occorrenze di un errore non ripetono più quindici volte la stessa cosa**: nel dettaglio di un errore se ne vedono cinque, con una riga di riepilogo per ciò che non cambia mai — ambiente, rilascio, livello. Le altre si aprono con «Mostra le altre», senza perdere i filtri. [Errori](/member/monitoring/error)

- **Quando i filtri non trovano nessun errore, si tolgono tutti insieme**: accanto al messaggio di elenco vuoto c'è ora il comando che toglie tutti i filtri in un gesto. E se il vuoto dipende dall'ambiente scelto, la pagina lo dice. [Errori](/member/monitoring/error)

### Fixed

- **In Home le notifiche sui ticket e quelle dei sistemi hanno due riquadri distinti, ognuno col suo numero**: menzioni, commenti e revisioni sui ticket stanno in un riquadro, gli avvisi delle macchine in un altro, e ognuno porta al proprio elenco con lo stesso numero. Prima il collegamento portava su un elenco coi numeri diversi. [Notifiche](/member/alerting/notifications)

- **Le macchine che compilano il codice non avvisano più per i contenitori di ogni lavorazione**: i database temporanei accesi e spenti da ogni lavorazione generavano decine di falsi avvisi di contenitore caduto. Ora si riconoscono da soli dal nome e tacciono, mentre un contenitore che cade davvero avvisa come prima. [Macchine](/member/monitoring/servers)

## [0.105.0] - 2026-08-14

### Changed

- **«Preferenze» sono le tue, «Amministrazione» è quella del team**: l'area personale ora si chiama Preferenze e quella del team Amministrazione: prima si chiamavano tutte e due «Impostazioni» e ci si confondeva. Cambiano solo i nomi, non dove stanno le cose. [Preferenze](/member/preferences) e [Amministrazione](/member/settings)

- **Su un'idea già diventata ticket il comando principale apre quel ticket**: in cima all'idea c'è ora un pulsante col codice del ticket che lo apre; prima l'unico comando rimasto era quello per cancellarla. Cancellare è sceso in un menu, con una conferma che dice cosa si perde. [Idee](/member/ideas)

- **Nell'elenco delle idee si vede in quale ticket è finita ciascuna**: accanto allo stato c'è ora il codice del ticket nato dall'idea, che si apre premendolo; prima bisognava aprire le idee una per una. La colonna dei voti, ferma a zero, non c'è più. [Idee](/member/ideas)

- **Discutere un'idea non si ferma più dopo due righe**: il campo dei commenti accettava solo un messaggio brevissimo; ora accetta un ragionamento intero, qualche migliaio di caratteri. Gli interventi lunghi arrivano ritagliati con «Mostra tutto», e un commento rifiutato torna col testo ancora nel campo. [Idee](/member/ideas)

### Fixed

- **Le conversazioni, quando non ce n'è ancora nessuna, dicono a cosa servono**: la pagina vuota ora spiega a cosa serve questo spazio — parlare in diretta coi colleghi — e in cosa differisce dai commenti sui ticket, con un esempio per ciascuno. Prima mostrava due frasi che si contraddicevano. [Conversazioni](/member/chat/conversations)

## [0.104.0] - 2026-08-14

### Fixed

- **Nella scheda di un agente non compaiono più misure sempre vuote**: una misura che non si può ancora calcolare non compare più: riquadro e colonna arrivano solo quando c'è qualcosa da mostrare. Una riga spiega anche la differenza fra «Tempo dell'agente» e «Tempo di lavorazione». [Agenti](/member/agents)

- **I recapiti degli avvisi si trovano dal menu, e la pagina dice come si chiama**: «Canali di consegna» è ora una voce del menu, sotto le notifiche, e la pagina ha il suo nome nella scheda del browser. Creando una regola senza recapiti, è scritto che gli avvisi arrivano comunque nell'app e per email. [Canali di consegna](/member/alerting/channels)

- **Chi ascolta la pagina sente la data del guasto, non un codice**: nell'elenco dei guasti, chi si fa leggere la pagina sentiva un codice al posto della data. Ora selezione e comandi dicono giorno e ora d'inizio del guasto; sullo schermo non cambia nulla. [Uptime](/member/monitoring/monitors)

- **Le voci del menu si chiamano come le pagine che aprono**: alcune voci del menu avevano un nome diverso dalla pagina che aprivano, e un paio erano in inglese. Ora ogni voce porta il nome della sua pagina, e un controllo automatico impedisce nuove differenze. [Conversazioni](/member/chat/conversations), [Session replay](/member/monitoring/replays) e [Vault](/member/vault)

- **La conoscenza correlata propone solo materiale che c'entra davvero**: il riquadro suggeriva a volte documenti fuori tema o cinque voci quasi identiche. Ora mostra al massimo tre voci, ognuna col motivo per cui è lì, e sparisce quando non c'è niente di pertinente. [Ticket](/member/tickets) e [Errori](/member/monitoring/error)

## [0.103.0] - 2026-08-14

### Changed

- **Le guide sui segreti dicono in cima dove va una password**: le due guide aprono ora spiegando la differenza fra Vault e secret dell'organizzazione, con la regola pratica: serve solo a te, a un progetto o a più progetti. Da una si passa all'altra con un clic. [Vault](/member/vault) ([guida](/member/guides/vault)) e [Secret dell'organizzazione](/member/shared/secrets) ([guida](/member/guides/secrets))

- **Le novità si consultano: cerchi, filtri, e trovi cosa è cambiato su una funzione**: la pagina ha ora la ricerca nel testo, il filtro per area e per tipo di modifica, e le versioni arrivano a pagine invece che tutte insieme. Le aree si chiamano come nel menu. [Novità](/member/changelog)

- **La pagina di Telegram dice cosa ti arriva e come ci si collega**: la pagina ora spiega cosa manda il bot, i passi per collegarsi e cosa puoi chiedergli scrivendogli — aprire un ticket, vedere i tuoi, commentarne uno. Il pulsante per scollegarsi è sceso in fondo. [Telegram](/member/preferences/telegram)

- **Le notifiche si sistemano in un minuto, invece che scorrendo tutta la pagina**: gli avvisi stanno ora in gruppi che si aprono e si chiudono, con un campo di ricerca per nome e tre configurazioni pronte — Essenziale, Tutto, Solo urgenze — che sistemano tutto in un gesto. Canali e ore di silenzio restano come li hai messi. [Notifiche](/member/preferences/notifications)

### Fixed

- **Un ticket appena creato non sembra più guasto**: la scheda diceva insieme «in coda» e «mai partito», contraddicendosi. Ora dice che è in coda, da quanto aspetta e che di solito parte entro pochi minuti; il comando per annullare è in secondo piano e spiega cosa comporta. [Ticket](/member/tickets) ([guida](/member/guides/agents))

- **I collegamenti dentro le novità portano dove dicono**: qualche nota rimandava a una pagina che nel frattempo si era spostata, e cliccarla finiva su un errore. Ora quei collegamenti sono giusti, e un controllo automatico impedisce che una nota nuova ne contenga uno che non porta da nessuna parte. [Novità](/member/changelog)

- **I testi scritti in automatico hanno gli accenti al posto giusto**: i testi generati dal sistema arrivavano spesso senza accenti — «gia», «perche». Ora l'ortografia italiana è richiesta e un controllo corregge le parole sbagliate più comuni prima del salvataggio, senza toccare codice e indirizzi. [Ticket](/member/tickets)

## [0.102.0] - 2026-08-14

### Added

- **Il Vault dice cosa sa fare, invece di lasciarlo scoprire per caso**: nel menu dell'area c'è ora «Cosa puoi fare qui», che elenca le funzioni una per una, con un esempio e il collegamento al posto dove si usano. In fondo alla pagina iniziale si vede anche lo stato dei collegamenti automatici. [Vault](/member/vault) ([guida](/member/guides/vault))

- **Una guida racconta come lavorano le macchine che ti fanno il lavoro**: una guida nuova segue un lavoro automatico dall'inizio alla fine e dice dove la parola passa a te, cosa significa ogni esito e cosa succede se nessuno risponde a una richiesta. Si apre dall'elenco delle macchine e dalle approvazioni. [Agenti](/member/agents) ([guida](/member/guides/agents))

- **Una guida spiega le versioni delle competenze, prima che si tocchi qualcosa**: una guida nuova dice cosa sono le istruzioni versionate delle macchine, come leggere la tabella dell'allineamento e cosa comporta tornare a una versione precedente. [Agenti](/member/agents) ([guida](/member/guides/skill-bundles))

- **Si vede a colpo d'occhio se la nuova versione delle competenze è arrivata su tutte le macchine**: in cima alla pagina c'è ora una tabella con, per ogni macchina, la versione attesa e quella in uso, più il conteggio di quante sono allineate. Chi non dichiara la versione risulta «non dichiarata», non guasta. [Agenti](/member/agents)

### Changed

- **Un lavoro respinto si chiama così dappertutto**: lo stesso esito aveva tre nomi — respinti, bocciato, rifiuta. Ora la parola è una sola, «respinto», ovunque: riquadri, colonne, guide e avvisi, comprese le richieste di modifica ai dati riservati. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

- **Le statistiche del sito si chiamano sempre allo stesso modo**: il nome è ora uno solo — «Statistiche del sito» — nel menu, nel titolo, nelle guide e in ogni rimando; prima nel menu erano «Analytics». Anche le aree del menu portano tutte nomi italiani. [Statistiche del sito](/member/monitoring/analytics) ([guida](/member/guides/analytics))

- **La guida delle statistiche mostra il codice da incollare, già pronto per il tuo sito**: il codice da inserire nel sito ora sta nella guida, compilato per il progetto che scegli e col pulsante per copiarlo. Senza il permesso sulle chiavi trovi un segnaposto con scritto a chi chiederla. ([guida](/member/guides/analytics))

- **I Dataset dicono a cosa servono, con un esempio**: la sezione spiega ora a cosa serve con un esempio concreto — smistare le segnalazioni fra guasti e richieste — e cosa non è. Una guida nuova dice quando conviene e quanto fidarsi delle risposte. [Dataset](/member/datasets) ([guida](/member/guides/datasets))

- **La pagina che fissa la versione delle competenze non sta più nel menu di tutti**: è pura amministrazione, quindi ora si apre dalla pagina delle macchine e solo con il permesso di amministrarle. La scheda del browser porta il nome della pagina e la data è scritta in italiano. [Agenti](/member/agents)

## [0.101.0] - 2026-08-14

### Added

- **Collegare due pagine si scopre scrivendo, non leggendo la guida**: aprendo le doppie parentesi quadre nel contenuto compaiono i titoli delle pagine collegabili: ne scegli uno e il collegamento è fatto. La colonna di destra mostra sempre cosa collega la pagina e chi la cita. [Conoscenza](/member/knowledge) ([guida](/member/guides/knowledge))

- **La guida della conoscenza spiega anche le raccolte, e ci si arriva dalla pagina giusta**: la guida ha ora un capitolo sulle raccolte — a cosa servono, come si ordina, cosa succede a una pagina inserita — e il collegamento dalla pagina delle raccolte porta dritto lì. [Conoscenza](/member/knowledge) ([guida](/member/guides/knowledge))

### Changed

- **Il Vault ha un menu più corto e un posto solo per le cose da sistemare**: le voci del menu passano da undici a sei: variabili e file dello stesso tipo stanno insieme, e tutto ciò che chiede una mossa sta in una lista sola ordinata dal più rischioso. I vecchi indirizzi continuano a funzionare. [Vault](/member/vault)

- **Nella coda delle proposte si legge prima di decidere**: la proposta viene ora prima dei bottoni, con motivazione e testo già aperti, e accanto a ogni bottone è scritto cosa provoca. L'avviso che le proposte in attesa restano fuori dalla ricerca è in chiaro sopra la fila. [Revisione](/member/knowledge/reviews) ([guida](/member/guides/knowledge-review))

### Fixed

- **Le spiegazioni accanto ai titoli si leggono per intero anche da telefono**: passando sul pallino con la «i» che sta accanto al titolo di una pagina compare un riquadro con la spiegazione; su schermo stretto usciva dal bordo sinistro e la frase si leggeva tagliata a metà. Ora il riquadro resta dentro lo schermo, in tutte le pagine del prodotto.

- **Un dato mancante ferma subito l'invio dei segreti, senza lasciare il comando in attesa**: se uno degli ambienti richiede una variabile non ancora impostata, ora il problema viene segnalato prima di accodare il lavoro. Il comando non resta più ad aspettare un aggiornamento che non potrà arrivare.

## [0.100.0] - 2026-08-14

### Added

- **La ricerca di una variabile porta dritto alla variabile, e dice dove manca**: ogni risultato apre direttamente i segreti di quel progetto con la riga già evidenziata, e per ogni progetto si vede in quali ambienti la variabile non è impostata. Il valore resta sempre nascosto. [Vault](/member/vault)

- **I server si organizzano in gruppi e l'elenco si filtra per quello che conta**: a ogni macchina puoi dare uno o più gruppi — produzione, collaudo — e premendone uno l'elenco mostra solo quello. Il riquadro «Da fare» porta anche alle macchine col disco quasi pieno. [Server](/member/monitoring/servers)

- **Le macchine propongono i progetti da collegare e spiegano cosa vuol dire «collegato»**: una riga spiega che il collegamento si imposta a mano, e quando manca la pagina propone i progetti probabili riconoscendoli dai nomi di ciò che gira sulla macchina. Niente viene collegato da solo. [Server](/member/monitoring/servers)

- **L'elenco dei database dice cosa sta crescendo, e la variazione dichiara su quanti giorni**: c'è una colonna ordinabile con la crescita degli ultimi sette giorni, e nella scheda l'etichetta dice su che periodo è calcolata. Dove la storia non basta compare un trattino, non uno zero. [Database](/member/monitoring/databases)

### Changed

- **Le due code di approvazione non hanno più nomi che si somigliano**: quella generale resta «Approvazioni», quella del Vault si chiama «Modifiche ai segreti». Quando è vuota, quella dei segreti spiega come funziona invece di mostrare il nulla. [Approvazioni](/member/home/approvals)

- **La pagina dei segreti dice in chiaro come sono protetti e chi può leggerli**: la pagina scrive che i segreti sono cifrati e che ogni lettura resta registrata, e salvando un segreto si vede chi potrà leggerlo. Vale anche per i segreti personali e per quelli dell'organizzazione. [Vault](/member/vault)

- **Il riepilogo dell'infrastruttura conta anche le macchine spente**: le macchine spente non comparivano nel riepilogo; ora hanno la loro riga, che porta all'elenco già filtrato su quelle giù. Corretta anche la riga degli avvisi, che mostrava una sigla interna. [Infrastruttura](/member/monitoring/servers)

## [0.99.0] - 2026-08-14

### Changed

- **La temperatura sparisce dove nessuno la misura**: colonna e grafico della temperatura restavano sempre vuoti perché le macchine attuali non hanno il sensore; ora compaiono solo dove il dato arriva davvero. Tutto ricompare da sé quando si collega una macchina che la misura. [Server](/member/monitoring/servers)

- **La percentuale di un database dice su cosa è calcolata, e il suo nome non promette più un limite**: la colonna sembrava un limite di spazio, ma è il peso rispetto agli altri database della stessa macchina. Ora si chiama «% dei database del server» e al passaggio dice su quale totale è calcolata. [Database](/member/monitoring/databases)

- **La scheda di una macchina non elenca più decine di servizi tutti uguali per dire che va tutto bene**: quando nessun servizio è in errore, ora lo dice in una riga; l'elenco completo resta a un clic. Le voci ferme per un motivo normale non si confondono più con quelle anomale. [Server](/member/monitoring/servers)

- **La pagina dei codici di accesso dice quante macchine li usano e non ne fa più annullare uno per sbaglio**: ogni codice mostra ora quante macchine ci sono collegate e dice che non scade; per annullarlo bisogna riscriverne il nome, con davanti quante macchine ne saranno coinvolte. La pagina spiega anche cosa fare se un codice va perso. [Codici di accesso](/member/monitoring/tokens)

- **Sulla scheda di una macchina i comandi che tolgono dati non si premono più per sbaglio, e ognuno dice cosa fa**: ogni comando dice ora su cosa agisce — «Sospendi gli avvisi», «Scollega dalla flotta», «Elimina». I due che fanno perdere dati stanno in un menu a parte e chiedono di riscrivere il nome della macchina. [Server](/member/monitoring/servers)

## [0.98.0] - 2026-08-13

### Changed

- **La pagina iniziale dell'Infrastruttura dice cosa non va, invece di ripetere il menu**: la pagina mette ora per prime le cose che non vanno — un sito giù, un lavoro mancato, le notifiche non lette — con la durata e un collegamento per andarci subito. Quando è tutto a posto lo scrive.

- **La parola «Avvisi» non porta più a due pagine diverse**: nel menu ora si chiamano «Regole di avviso» e «Notifiche»: due nomi diversi, due pagine diverse. Le notifiche ricevute stanno anche nel menu, non solo dietro la campanella. [Regole di avviso](/member/alerting/rules) · [Notifiche](/member/alerting/notifications)

- **Sul controllo di un sito il comando che serve è uno solo, gli altri non si premono per sbaglio**: in primo piano resta solo «Modifica»; pausa ed eliminazione stanno in un menu a parte, chiedono conferma e spiegano cosa comportano. Se il sito è pubblico o privato è scritto in cima come stato. [Uptime](/member/monitoring/monitors)

- **Dall'elenco dei siti si vede subito da quanto uno è giù**: un sito che non risponde dice ora da quanto dura il guasto — «Giù da 3h 09m» — e i siti che stanno male compaiono per primi. I contatori «Su» e «Giù» si premono per filtrare. [Uptime](/member/monitoring/monitors)

- **La pagina di una regola di avviso spiega in parole semplici cosa fa e quando è scattata**: la pagina descrive ora la regola in una frase — cosa la fa scattare, dove vale, ogni quanto avvisa — e mostra lo storico degli scatti. Modificarla resta un gesto a parte. [Regole di avviso](/member/alerting/rules)

- **Le notifiche si separano per tipo e i guasti gravi saltano all'occhio**: in cima ci sono ora le schede Tutte, Ticket, Sistemi e Agenti, ognuna col conteggio delle non lette. La caduta di un servizio importante si riconosce a colpo d'occhio. [Notifiche](/member/alerting/notifications)

## [0.97.0] - 2026-08-13

### Added

- **Ora si scopre come mettere un lavoro programmato sotto controllo**: il nuovo comando «Aggiungi un lavoro» apre le istruzioni: l'indirizzo da chiamare, il comando pronto da copiare, come segnalare un fallimento. C'è anche una guida dedicata. [Cron](/member/monitoring/cron) · [Guide](/member/guides)

### Changed

- **Un menu solo, uguale in ogni pagina, con i gruppi che si aprono e si chiudono**: il menu di sinistra ora contiene tutto e non cambia mai forma: in cima le cinque cose di ogni giorno, sotto i gruppi che si aprono e restano come li lasci. Sparisce il selettore d'area in alto. ([guida](/member/guides/overview))

## [0.96.0] - 2026-08-13

### Added

- **La pagina di un lavoro programmato dice da quanto è fermo, perché, e cosa puoi farci**: la pagina dichiara ora da quanto dura lo stato attuale, raccoglie i tentativi falliti di fila in un guasto solo e mostra il motivo di ogni fallimento. Spiega anche la differenza fra «mancato» e «fallito». [Cron](/member/monitoring/cron)

- **I lavori programmati si possono correggere, sospendere ed eliminare**: prima erano in sola lettura; ora hanno le stesse azioni dei siti sotto controllo — correggere il nome, allungare la tolleranza, sospenderli. La creazione resta al primo check-in. [Cron](/member/monitoring/cron)

- **Un lavoro può dire perché è fallito**: chi manda il check-in può allegare il motivo in parole, e quello compare sulla pagina accanto al tentativo. Chi non lo manda continua a funzionare esattamente come prima. [Cron](/member/monitoring/cron)

### Fixed

- **Le impostazioni opzionali lasciate vuote non bloccano più l'invio dei file segreti a GitHub**: un valore vuoto scelto intenzionalmente veniva scambiato per un dato mancante e fermava l'aggiornamento di tutti gli ambienti. Ora resta vuoto come richiesto; se un dato manca davvero, il comando lo segnala prima di mettersi in attesa.
## [0.95.1] - 2026-08-13

### Added

- **Prestazioni e log si aprono con alcune viste già pronte, invece che con un foglio bianco**: ci sono tre punti di partenza per parte, come i rallentamenti recenti o gli errori più gravi. Sono scorciatoie: i filtri restano modificabili. [Prestazioni](/member/monitoring/performance) · [Log](/member/monitoring/logs)

## [0.95.0] - 2026-08-13

### Added

- **Sopra i log c'è un grafico che mostra quando è successo qualcosa**: mostra il volume dei messaggi nel tempo, coi blocchi accesi dove ci sono messaggi allarmanti. Un clic su un blocco restringe l'elenco a quel momento. [Log](/member/monitoring/logs)

### Fixed

- **I conteggi in cima ai log seguono il filtro**: prima restavano identici anche con una ricerca attiva. Ora dicono quante voci ha il risultato, col totale accanto. [Log](/member/monitoring/logs)

### Changed

- **Quando i valori di un rallentamento non vengono raccolti, la pagina dice esattamente cosa scrivere**: mostra la riga esatta da aggiungere, con pulsante per copiarla e collegamento alla guida. Le voci senza un valore non si mostrano più. [Prestazioni](/member/monitoring/performance)

- **Le guide di prestazioni e log ora dicono davvero come si collega un'applicazione**: prima si fermavano a metà. Ora hanno pacchetto, configurazione e indirizzo, e tutti i tipi di rallentamento sono spiegati. [Guide](/member/guides)

### Added

- **I messaggi uguali si possono raggruppare, per sapere quanti problemi diversi ci sono davvero**: un interruttore mostra una riga per messaggio, con quante volte è comparso e quando. La scelta resta nell'indirizzo, così si condivide. [Log](/member/monitoring/logs)

- **Da un messaggio si apre un ticket, come già si faceva da un rallentamento**: un pulsante apre un ticket già compilato con testo, progetto, ambiente e versione. Se il ticket esiste già, si collega a quello e te lo dice. [Log](/member/monitoring/logs)

## [0.94.0] - 2026-08-13

### Changed

- **La guida per collegare un'applicazione vale per tutti i linguaggi, non per uno solo**: prima copriva solo Ruby. Ora si sceglie il proprio kit (Ruby, JavaScript, Flutter) e si vedono le istruzioni giuste, col percorso di menu corretto. [Guide](/member/guides)

### Added

- **Una regola di avviso si può silenziare su una sola macchina, invece di spegnerla per tutte**: dalla scheda di una macchina si silenzia lì la singola regola. Il silenzio resta visibile, col comando per toglierlo. [Server](/member/monitoring/servers)

- **I nomi dei contenitori da ignorare si impostano anche da terminale**: prima si compilavano solo dalla pagina web. Ora si leggono e si scrivono con i comandi dei server. [Server](/member/monitoring/servers)

### Fixed

- **L'avviso «macchina ferma» diceva la cosa sbagliata, e la ripeteva ogni ora**: ora dice che è ferma l'automazione, non il computer, porta alla sua scheda e i promemoria si diradano nel tempo. [Avvisi](/member/alerting/rules)

### Changed

- **La pagina d'ingresso dell'osservabilità dice come sta il sistema, invece di ripetere il menu**: ogni sezione ha una scheda con un numero aggiornato e una riga che dice a cosa serve. [Osservabilità](/member/observability)

- **La roadmap di un progetto senza obiettivi di rilascio spiega cosa sono, invece di essere una lista piatta**: finché non esiste il primo obiettivo, la pagina spiega a cosa servono, fa un esempio e porta a crearne uno. [Roadmap di progetto](/member/projects)

## [0.93.0] - 2026-08-13

### Changed

- **Le attività personali hanno una voce nel menu, non solo un'icona senza nome**: ora stanno nel menu accanto a Conversazioni, Idee e Ticket, con la scorciatoia da tastiera «g» poi «d». L'icona in alto resta. [Attività](/member/lists)

- **Per collegare un ticket si scrive il codice, invece di scorrere duecento voci**: il campo parte dai ticket recenti e cerca sul server mentre scrivi la sigla o una parola del titolo. [Carico di lavoro](/member/workload/actions) · [Liste](/member/lists)

- **Le sezioni vuote spiegano cosa metterci, invece di dire solo che manca qualcosa**: ogni sezione vuota dice cosa manca, a cosa serve, un esempio concreto e il pulsante per farlo subito. [Disponibilità](/member/monitoring/monitors)

- **L'elenco dei ticket dà spazio al titolo e si sfoglia meno**: il titolo prende tutto lo spazio libero su due righe, le colonne vuote spariscono e si sceglie quante righe vedere per pagina. [Ticket](/member/tickets)

- **Analisi e piani si leggono, invece di essere muri di testo**: in cima c'è chi ha scritto e quando, il testo lungo parte accorciato e i riferimenti ai file sono segnati come codice. [Ticket](/member/tickets)


## [0.92.5] - 2026-08-12

## [0.92.4] - 2026-08-12

### Added

- **Una macchina dismessa si può togliere dall'elenco**: dalla sua scheda la si elimina, dopo una conferma che dice quanto storico va perso. Una macchina ancora al lavoro non si elimina per sbaglio. [Agenti](/member/agents)

## [0.92.3] - 2026-08-12

### Changed

- **Nel ticket l'approvazione non sta più accanto alla cancellazione**: una decisione in sospeso compare in cima al ticket, con contesto e un solo bottone principale. Modificare ed eliminare sono passati in un menu. [Ticket](/member/tickets)

- **La pagina che risponde alle domande sui ticket smette di essere un campo bianco**: ora dice cosa sa fare, propone tre domande da provare con un clic e conserva le domande recenti. [Ticket](/member/tickets)

- **Le viste salvate spiegano a cosa servono, e ne trovi già due pronte**: il pannello dice cosa salva, offre «Aspettano me» e «Aperti ad alta priorità», e sta accanto ai filtri che salva. [Ticket](/member/tickets)

- **La sigla di un ticket dice a quale progetto appartiene**: nel dettaglio il codice sta accanto al nome del progetto, con collegamento, e passandoci sopra col mouse si legge a chi appartiene. [Ticket](/member/tickets)

## [0.92.2] - 2026-08-12

## [0.92.1] - 2026-08-12

### Changed

- **Le guide spiegano tutto il prodotto, non un terzo**: sotto le guide approfondite ora c'è l'elenco completo delle pagine, area per area, con una riga di spiegazione ciascuna. [Guide](/member/guides)

- **Il percorso in alto dice anche in che area sei, e la pagina iniziale ha un nome solo**: ora si legge «Home / Applicativi / Ticket / …», con l'area cliccabile e coerente col menu. [Ticket](/member/tickets)

- **Entrare in un'area ora dice com'è messa, invece di ripetere il menu**: ogni area apre coi suoi numeri veri, letti dalle stesse fonti delle pagine a cui porta. [Osservabilità](/member/observability)

- **«Avvisi» indica un posto solo, e i collegamenti si chiamano come la pagina che aprono**: la campanella ora si chiama Notifiche, «Avvisi» resta il nome delle regole di allarme. [Notifiche](/member/alerting/notifications)

- **La Home apre con cosa fare adesso, non con tre numeri ripetuti**: sotto il saluto ora c'è quante cose aspettano una tua risposta e da quanto, più le lavorazioni che vanno avanti da sole. [Home](/member/home)

## [0.92.0] - 2026-08-12

### Fixed

- **Scegliere l'italiano ora vale davvero per tutta l'interfaccia**: restavano scritte inglesi fisse come «Cancel» e «N selected». Ora passano dalle traduzioni e un controllo automatico impedisce che tornino.

### Fixed

- **Le statistiche del sito dicono anche come sta andando, non solo quanto**: ogni numero porta la variazione rispetto al periodo precedente, e le visite di controllo non gonfiano più i totali. [Statistiche](/member/monitoring/analytics)

## [0.91.3] - 2026-08-12

### Fixed

- **La scheda di una macchina smette di contraddirsi**: prima tre conteggi dicevano tre cose diverse. Ora i numeri raccontano la stessa cosa, le sigle dei progetti sono nomi con link e i programmi installati stanno in una tabella. [Macchine al lavoro](/member/agents)

- **Date, mesi ed etichette finiscono di essere scritti a metà in inglese**: sparivano mesi come «Aug», canali come «Direct» e un messaggio di errore al posto di un'etichetta. Ora è tutto in italiano. [Prestazioni](/member/monitoring/performance)

- **I comandi dentro le pagine si leggono per intero e si copiano con un gesto**: prima le righe lunghe si copiavano tagliate senza accorgersene. Ora i blocchi di codice scorrono, segnalano il testo nascosto e hanno un bottone che copia la riga intera. [Conoscenza](/member/knowledge/pages)

## [0.91.2] - 2026-08-12

### Fixed

- **Il livello semplice delle pagine di conoscenza torna a voler dire qualcosa**: la scelta fra «Semplice» e «Tecnico» compare solo quando i due livelli esistono davvero, e l'avviso «troppo tecnico» arriva a chi scrive, non a chi legge. [Conoscenza](/member/knowledge/pages)

- **Meno gergo e una lingua sola nella pagina di una macchina**: gli stati delle connessioni sono scritti a parole, col nome tecnico al passaggio del mouse, e spariscono «1 pacchetti» e le doppie lingue. [Macchine](/member/monitoring/servers)

- **Le attività sui secret si leggono in italiano, e sempre con le stesse parole**: ogni azione ha una parola italiana sola, uguale in tutte le liste, e il tempo mostra data e ora esatte al passaggio del mouse. [Secret personali](/member/personal/secrets)

- **Nell'elenco dei programmi in esecuzione si capisce cosa gira**: il codice si mostra accorciato, l'indirizzo non è più ripetuto due volte e «none» ora si legge «nessun controllo». [Macchine](/member/monitoring/servers)

## [0.91.1] - 2026-08-12

### Fixed

- **Gli avvisi si chiamano tutti nella stessa lingua**: le regole preconfigurate portano il nome italiano del loro evento; quelle rinominate restano come le hai chiamate. Tradotti anche gli stati «Up» e «Down». [Avvisi](/member/alerting/rules)

## [0.91.0] - 2026-08-12

### Fixed

- **Gli avvisi sui servizi caduti smettono di suonare per le compilazioni**: prima segnalavano come guasti i contenitori temporanei di compilazione. Ora sono esclusi di default, e ogni macchina può dichiarare altri nomi da ignorare. [Macchine](/member/monitoring/servers)

### Fixed

- **La disponibilità dice su quanto tempo è calcolata**: quando la copertura è parziale, accanto alla percentuale c'è su quanta parte del periodo si regge, e una riga spiega perché mancano dei pezzi. [Uptime](/member/monitoring/monitors)

### Fixed

- **Nella scheda di un rallentamento i due numeri dicono cosa contano**: prima sembravano contraddirsi. Ora uno è «occorrenze totali», l'altro dice quanti casi sono ancora conservati, e una riga spiega la differenza. [Prestazioni](/member/monitoring/performance)

### Fixed

- **La tabella delle prestazioni si legge su uno schermo normale**: le colonne più utili vengono prima, la prima colonna ha larghezza fissa e una sfumatura sul bordo segnala il contenuto fuori schermo. [Prestazioni](/member/monitoring/performance)

## [0.90.0] - 2026-08-12

### Fixed

- **Il filtro dei registri dice quanto c'è, e la pagina vuota non è più un vicolo cieco**: accanto a ogni livello c'è quante voci ha, quelli a zero non si scelgono, e la pagina vuota spiega la causa probabile con il pulsante per togliere i filtri. [Registri](/member/monitoring/logs) ([guida](/member/guides/logs))

### Fixed

- **Il codice del rilascio si legge, si copia e porta al commit**: prima si accavallava fino a non leggersi. Ora si mostra accorciato, si copia intero con un clic e apre la modifica corrispondente nel repository. [Errori](/member/monitoring/error)

### Fixed

- **Dal dettaglio di un errore si arriva ai registri di quella richiesta**: il codice della richiesta ora è cliccabile e apre i registri. Se non ce ne sono, la pagina spiega perché. [Errori](/member/monitoring/error)

### Fixed

- **Una parola sola per ogni cosa, e i livelli si leggono in italiano**: l'errore si chiama errore ovunque, i livelli di gravità sono «avviso», «errore», «bloccante» e i passi prima di un blocco hanno un nome chiaro. [Errori](/member/monitoring/error)

### Fixed

- **I contatori sopra l'elenco degli errori tornano, e filtrano**: prima contavano insiemi diversi e la somma non tornava. Ora contano sullo stesso insieme, la somma torna e un clic su ognuno mostra solo quegli errori. [Errori](/member/monitoring/error)

## [0.89.4] - 2026-08-12

### Fixed

- **Il menu laterale dice sempre in che area sei**: prima certe pagine mostravano il menu di un'altra area. Ora ogni pagina dichiara la sua, la voce giusta è evidenziata e un controllo automatico impedisce che una pagina nuova resti senza. [Progetti](/member/projects)

## [0.89.3] - 2026-08-12

### Fixed

- **Fuori dalle pagine del prodotto l'errore non è più una schermata bianca in inglese**: la pagina di errore ora è sempre quella del prodotto, in italiano, col menu e il pulsante per tornare alla home. [Attività del team](/member/workload/actions)

- **Le «operazioni più lente» di un progetto si leggono, e i numeri assurdi sono segnalati**: ogni riga dice cosa tocca, le righe dell'infrastruttura non compaiono più e un valore fuori scala porta scritto «misura sospetta». [Progetti](/member/projects)

- **Via le ultime parole inglesi infilate nelle frasi italiane**: «case», «action» e «book» ora si leggono «casi d'uso», «attività» e «raccolte», dappertutto. I nomi di prodotto restano quelli che sono. [Idee](/member/ideas) · [Attività del team](/member/workload/actions)

## [0.89.2] - 2026-08-12

### Fixed

- **Il registro delle modifiche non attribuisce più il lavoro a «Qualcuno»**: le automazioni ora si dichiarano per nome, con l'icona di una macchina invece delle iniziali riservate alle persone. [Ticket](/member/tickets)

- **L'icona che dice chi lavora un ticket ora si legge**: prima era solo una sfumatura di colore. Ora i tre casi hanno tre forme diverse (robot, clessidra, persona), col nome al passaggio del mouse e la legenda sotto l'elenco. [Ticket](/member/tickets)

- **I ticket nati da un errore hanno un titolo che si legge**: il titolo dice cosa non funziona e dove, il messaggio tecnico resta nel corpo, e nessun titolo occupa più di due righe. [Ticket](/member/tickets)

- **Creare un ticket chiede meno cose e dice cosa succede dopo**: lo stato iniziale è solo mostrato, la priorità proposta è quella media e sotto il pulsante c'è scritto che un'automazione può prendere in carico il ticket. [Ticket](/member/tickets)

- **Nessuna voce di menu mostra più un messaggio tecnico**: dieci voci senza traduzione ora ci sono in entrambe le lingue, e un controllo automatico impedisce che ne manchi una.

## [0.89.1] - 2026-08-11

### Fixed

- **Rilascio tecnico**: nessun cambiamento visibile. Questa versione non ha raggiunto la produzione, e le sue novità viaggiano nella successiva.

## [0.89.0] - 2026-08-11

### Fixed

- **Via le parole inglesi rimaste in mezzo all'italiano**: «Idee pending», «Todos» e «Board» ora si leggono «Idee da valutare», «Attività» e «Bacheca», e un controllo automatico impedisce che rientrino.

- **Il link a una richiesta già decisa non butta più fuori dalla coda**: prima compariva una pagina di errore in inglese. Ora la coda si carica e un riquadro dice che la richiesta è già stata decisa, da chi e quando. [Approvazioni](/member/home/approvals)

- **Le date non sono più mezze in inglese, e a qualche giorno di distanza dicono il giorno**: sparite scritte come «4 days fa». Oltre i tre giorni si legge il giorno in forma breve, tipo «gio 6 ago». [Home](/) · [Approvazioni](/member/home/approvals)

### Added

- **Ogni permesso dice cosa concede, e i più delicati lo dichiarano**: ogni permesso ha un nome italiano e una spiegazione, quelli rischiosi portano l'avviso «delicato», e i ruoli si guardano in sola lettura. [Ruoli](/member/roles) ([guida](/member/guides/permissions))

- **Due guide che spiegano il prodotto, non una funzione**: «Come è fatto CloseYourIt» presenta tutte le aree e le prime cose da fare; «Il percorso di un ticket» racconta stati, bacheca e roadmap. [Guide](/member/guides)

### Changed

- **La pagina di ingresso di AI e Automazione dice come stanno le cose**: ogni sezione ha una scheda con una frase e il dato aggiornato, con le approvazioni per prime. [AI e Automazione](/member/automation)

## [0.88.4] - 2026-08-11

### Added

- **La scheda di una macchina dice quanto costa, se sta migliorando e cosa c'è dietro i numeri**: ogni misura porta la variazione rispetto al periodo prima, c'è il costo stimato e da «Confronta» si mettono due macchine fianco a fianco. [Macchine AI](/member/agents)

## [0.88.3] - 2026-08-11

### Changed

- **Le statistiche dicono se il sito è collegato o se hai solo sbagliato periodo**: un sito mai collegato mostra il codice da incollare; se le visite ci sono ma in un altro periodo, compaiono l'ultima visita e il link a un periodo pieno. [Statistiche](/member/monitoring/analytics)

## [0.88.2] - 2026-08-11

### Changed

- **Dalla coda si vede quale automazione ha prodotto il lavoro, e viceversa**: ogni riga della coda porta il nome dell'automazione, cliccabile, e la scheda di una macchina dice quante decisioni aspetta, con il link alla coda già filtrata. [Approvazioni](/member/home/approvals)
- **Un nome solo per ogni cosa, in italiano**: l'area si chiama «Conoscenza e prodotto», le raccolte si chiamano «Raccolte» dappertutto e nel modulo di scrittura si scrive «Prodotti». I link salvati continuano a funzionare. [Conoscenza](/member/knowledge/pages)
- **La pagina iniziale dei segreti dice cosa non va**: ora risponde a tre domande — cosa c'è dentro, cosa non va, cosa è successo — e ogni riga di attività si legge per intero. [Vault](/member/vault)
- **I segreti di un progetto si guardano restando nell'area dei segreti**: l'elenco dei progetti è una tabella con segreti, anomalie e ultima modifica, e da lì si apre tutto senza cambiare area. [Vault](/member/vault)

### Changed

- **L'elenco delle macchine dice cosa c'è da fare**: un riquadro in cima riassume riavvii, aggiornamenti e servizi caduti, con link alle macchine interessate. Se non c'è niente da fare, non compare. [Macchine](/member/monitoring/servers)
- **Un numero vecchio si riconosce come vecchio**: quando una macchina smette di mandare misure i suoi numeri perdono il colore, dicono di quando sono e lo stato diventa «Silenziosa». [Macchine](/member/monitoring/servers)

### Changed

- **Dalla pagina di una macchina si può finalmente fare qualcosa**: ora c'è «Apri un ticket su questa macchina», già compilato coi valori del momento, e il collegamento agli avvisi scattati. [Macchine](/member/monitoring/servers)
- **Collegare una macchina nuova si capisce e si porta a termine**: c'è il pulsante «Collega una macchina», istruzioni che si copiano con un clic e la pagina dice se sta ancora aspettando il primo contatto. [Macchine](/member/monitoring/servers)
- **L'elenco delle macchine mette in cima chi sta soffrendo**: le macchine oltre soglia hanno la cella accesa e stanno in cima, col conteggio in testata. L'ordine alfabetico resta a un clic. [Macchine](/member/monitoring/servers)
## [0.87.0] - 2026-08-11

### Added

- **La pagina di stato pubblica si trova, si vede e si incorpora**: ora ha la sua voce nel menu: da lì vedi cosa è pubblico, l'indirizzo che vedono i tuoi clienti, l'anteprima e il codice per metterla sul tuo sito. [Pagina di stato](/member/monitoring/status)
- **Modelli pronti per gli avvisi più comuni**: in cima alla creazione degli avvisi ci sono modelli pronti; quello della caduta di un sito crea anche la regola per sapere quando torna su. [Avvisi](/member/alerting/rules)
- **Il modulo di una regola mostra solo i campi che servono**: scegliendo l'evento restano soltanto i campi che lo riguardano, gli eventi sono raggruppati per famiglia con una riga che dice quando succedono, e «Throttle» si chiama «Raggruppa avvisi ripetuti». [Avvisi](/member/alerting/rules)
- **Un evento, un nome solo, e si capisce chi decide**: ogni evento ha lo stesso nome ovunque, email comprese, e le pagine spiegano che la regola decide se l'avviso nasce e le impostazioni personali se arriva a te. [Avvisi](/member/alerting/rules)
- **Si vede quale regola fa rumore, e la si può zittire per un po'**: l'elenco delle regole dice quante volte ciascuna è scattata e si ordina dalla più rumorosa; una regola si può silenziare per un'ora, un giorno o una settimana. Le notifiche si filtrano per tipo, progetto e lette o da leggere. [Avvisi](/member/alerting/rules)

## [0.86.1] - 2026-08-11

### Fixed

- **Niente più avvisi di contenitori caduti quando lo spegnimento è voluto**: il controllo dava per caduti i contenitori spenti apposta. Ora gli spegnimenti dichiarati restano silenziosi, mentre un contenitore che cade davvero continua ad avvisare. [Macchine](/member/monitoring/servers)

## [0.85.0] - 2026-08-11

### Added

- **La pagina di un progetto propone il passo successivo**: quando serve, compare un riquadro con al massimo tre proposte: aprire un ticket dall'errore più frequente, attivare il primo controllo di disponibilità, coprire un ambiente scoperto. [Progetti](/member/projects)
- **Un punto solo per aggiungere, che dice quale posto scegliere**: il «+» in alto apre una pagina che presenta i quattro posti dove annotare qualcosa — ticket, idea, promemoria personale, attività di team — con una riga che dice quando si usa ciascuno. [Ticket](/member/tickets)
- **Le librerie con problemi noti si guardano anche da riga di comando**: da terminale ora vedi l'elenco di tutti i progetti, con filtri, dettaglio e le stesse azioni del sito. Valgono gli stessi permessi. [Vulnerabilità](/member/monitoring/vulnerabilities)
- **La Home dice dove andare dopo**: in fondo alla Home c'è un blocco sempre visibile con tre uscite: il tuo lavoro, i ticket dei progetti e le guide. [Home](/)

### Changed

- **Le sigle dei progetti si leggono e si può guardare un progetto alla volta**: passando sopra una sigla si legge il nome per esteso, cliccandola si filtra su quel progetto; il filtro resta nell'indirizzo e si può mandare a un collega. [Approvazioni](/member/home/approvals)
- **Nella coda delle approvazioni si capisce ogni riga a colpo d'occhio**: ogni riga comincia col codice e il titolo del ticket, e il tipo di richiesta è un'etichetta breve. [Approvazioni](/member/home/approvals)

### Fixed

- **Sulla Home approvare e rifiutare sono pulsanti con la parola scritta**: prima erano due quadratini colorati senza testo. Ora ogni comando ha l'etichetta, e le righe senza comandi spiegano perché. [Home](/)
- **Negli errori si vede l'ambiente, e si parte da quello vero**: prova e sito vero stavano mescolati. Ora ogni riga mostra l'ambiente, c'è un filtro dedicato e senza filtri si vedono i non risolti del sito vero. [Errori](/member/monitoring/error)
- **Collegare un messaggio a un errore o a un ticket si fa leggendo, non a memoria**: ora ci sono due tendine separate — errori e ticket — ogni voce porta il titolo per intero e si può cercare scrivendo. [Log](/member/monitoring/logs)
- **I log si possono interrogare per campi, non solo indovinando le parole**: accanto all'elenco c'è la lista dei campi coi valori più frequenti: un clic restringe e il filtro si toglie da lì. [Log](/member/monitoring/logs)
- **Dall'errore al ticket si capisce cosa si crea e a che punto è**: prima di creare vedi un'anteprima del ticket; dopo, in cima all'errore, una barra dice su quale ticket si lavora, in che stato è e a chi è assegnato. [Errori](/member/monitoring/error)
- **Lo stesso errore in più punti si riconosce a colpo d'occhio**: la pagina di un errore mostra subito gli altri con lo stesso messaggio, e nell'elenco quelle righe dichiarano quante sono. [Errori](/member/monitoring/error)
- **La scheda della lavorazione automatica si legge in tre righe**: in cima ci sono tre righe — cosa ha fatto, perché si è fermata, cosa serve da te — e i tentativi interrotti sono raccolti in una riga sola apribile. [Ticket](/member/tickets)
- **«Workload» si chiama «Attività del team» e i suoi contatori dicono il vero**: la sezione ora ha il suo nome, spiega a cosa serve, e i contatori mostrano i numeri veri: prima segnavano zero anche con la lista piena. [Attività del team](/member/workload/actions)
- **I dati dei server arrivano subito anche quando c'è molto lavoro in corso**: prima restavano in coda col resto e la pagina mostrava dati vecchi. Ora hanno una corsia riservata e un arretrato altrove non li rallenta. [Macchine](/member/monitoring/servers)
- **La voce «Guide» nel menu si legge in italiano ed è in cima**: prima mostrava un testo tecnico in inglese e stava in fondo. Ora si chiama «Guide» e sta nel primo gruppo del menu, uguale in ogni area. [Guide](/member/guides)
- **Ogni pagina porta alla sua guida**: accanto al titolo di ogni pagina che ha una guida c'è un «Come funziona» che apre quella giusta. [Conoscenza](/member/knowledge/pages)

## [0.84.0] - 2026-08-11

### Fixed

- **Si vede quanto spazio resta su ogni disco della macchina**: prima c'era una sola percentuale, senza dire di quale disco. Ora trovi l'elenco dei dischi con lo spazio libero su ciascuno, e quelli quasi pieni si accendono di rosso. [Macchine](/member/monitoring/servers)

## [0.83.0] - 2026-08-10

### Added

- **La salute del Vault dice cosa manca, dove e da quando**: ogni segnalazione ora nomina la variabile e l'ambiente e dice da quando dura; puoi dichiarare che l'assenza è voluta e sparisce dall'elenco per tutti. [Vault](/member/vault)

### Fixed

- **I grafici di una macchina dicono da dove a dove arrivano**: prima erano colonne senza riferimenti. Ora hanno la scala da zero, riportano la dimensione della macchina, col mouse leggi i GB occupati, e la temperatura sopra i cento gradi non viene più tagliata. [Macchine](/member/monitoring/servers)

## [0.82.0] - 2026-08-10

### Added

- **Chiedere alla conoscenza senza sapere già cosa c'è dentro**: sopra la casella leggi quali progetti e quante pagine verranno consultati; sotto trovi domande d'esempio da toccare e le ultime domande del team con la risposta riapribile. [Conoscenza](/member/knowledge/pages)
- **L'area della conoscenza spiega in che ordine si usa**: la pagina d'ingresso presenta ogni voce con una definizione di una riga, il numero di cose in attesa e l'azione tipica, nell'ordine in cui si usano davvero. [Conoscenza](/member/knowledge/pages)

### Changed

- **Segreti dell'organizzazione più chiari e più sicuri da togliere**: la pagina spiega cosa vuol dire delegare un segreto a un progetto, e togliere quel permesso chiede conferma col nome del progetto e del segreto. [Segreti dell'organizzazione](/member/shared/secrets)

## [0.81.0] - 2026-08-10

### Added

- **Se la ricerca per significato smette di funzionare, ora lo sai**: quando il servizio interno cadeva, queste funzioni si fermavano in silenzio. Ora un controllo automatico lo prova ogni cinque minuti e manda un avviso se non risponde. [Avvisi](/member/alerting/rules)
- **Vulnerabilità delle librerie**: ogni notte CloseYourIt controlla le librerie dei progetti collegati a un repository e segnala quelle con problemi di sicurezza noti, con la versione a cui aggiornare; per i casi gravi apre da solo un ticket. [Vulnerabilità](/member/monitoring/vulnerabilities) ([guida](/member/guides/vulnerabilities))
- **Scegli tu per quanto tempo conservare i dati**: ora decidi tu quanti giorni tenere errori, tempi di risposta, dati delle macchine e storico della disponibilità: per l'intera organizzazione o progetto per progetto. [Organizzazione](/member/organization/edit)
- **Il mio lavoro**: una voce nel menu che apre l'elenco dei ticket assegnati a te, di tutti i progetti insieme, senza doverli cercare progetto per progetto. [Ticket](/member/tickets)
- **Cambiare stato dal ticket stesso**: fino a ieri lo stato si spostava solo trascinando la scheda sulla bacheca. Ora c'è un menu a tendina anche nel dettaglio del ticket, per chi può gestirlo. [Ticket](/member/tickets)
- **Da un ticket risali all'errore e ai messaggi che l'hanno originato**: nella pagina del ticket compaiono l'errore da cui è nato e i messaggi di log che gli hai agganciato, con il collegamento per aprirli. Lo stesso pannello c'è nella pagina dell'errore. [Ticket](/member/tickets)
- **Cronologia delle modifiche anche su idee, attività, documenti, dataset e traguardi**: prima si vedeva chi aveva cambiato cosa solo sui ticket. Ora ogni modifica lascia traccia anche in queste aree, con l'ultimo cambiamento in evidenza e lo storico completo a portata di clic. [Idee](/member/ideas)
- **Nell'elenco delle persone si distingue il livello dai permessi veri**: la colonna «Livello» dice solo come una persona appartiene all'organizzazione; una nuova colonna a fianco mostra i ruoli veri dati dai team e su cosa valgono. [Persone](/member/members)
- **La matrice delle funzionalità dice quanto sei coperto**: per ogni piattaforma vedi quante funzionalità attese sono già disponibili («1/1», «0/1»). Quando è vuota, la pagina mostra una riga d'esempio e i pulsanti per creare le prime voci.

### Changed

- **Avvisi più corti e raggruppati**: il messaggio ora dice quanti elementi sono coinvolti e su quale macchina, con l'elenco completo dentro l'avviso; gli avvisi ripetuti sullo stesso problema arrivano raggruppati. [Avvisi](/member/alerting/notifications)

### Fixed

- **L'automazione ferma mostra di nuovo come farla ripartire**: il riquadro col pulsante per riprovare compariva solo dopo vari tentativi falliti. Ora appare appena la lavorazione si ferma. [Ticket](/member/tickets)
- **Basta errori inventati dal monitoraggio stesso**: fra i tuoi errori comparivano segnalazioni di lentezza che non venivano dal tuo prodotto, ma dal lavoro che CloseYourIt fa per misurarlo. Ora quelle non vengono più registrate, e nell'elenco resta solo ciò che riguarda davvero il tuo software. [Errori](/member/monitoring/error)
- **Gli eventi di un repository restano nell'organizzazione giusta**: se lo stesso repository era collegato da due organizzazioni diverse, quello che succedeva su GitHub — nuovi rami, richieste di modifica — poteva finire agganciato al ticket dell'organizzazione sbagliata. Ora conta l'organizzazione da cui arriva l'evento. [Progetti](/member/projects)
- **Creare un'idea senza indicare gli stakeholder non dà più errore**: lasciando vuoto quel campo il salvataggio falliva con un errore di sistema invece di un normale avviso. [Idee](/member/ideas)

## [0.80.0] - 2026-08-10

### Added

- **Installare tutti gli aggiornamenti di una macchina, non solo quelli di sicurezza**: accanto al pulsante degli aggiornamenti di sicurezza ce n'è uno che installa tutti quelli in attesa. Compare sulle macchine col programma di controllo abbastanza aggiornato. [Macchine](/member/monitoring/servers)
- **Avvisi anche su visite, idee, attività e addestramenti**: ora arriva un avviso anche per visite fuori dal normale, idee aperte o commentate, attività in scadenza e addestramenti finiti o falliti; ognuno si accende o si spegne da solo. [Avvisi](/member/alerting/rules)
- **Avvisi quando un sito è lento, e controlli anche per servizi non-web**: puoi impostare una soglia di lentezza e ricevere un avviso quando la risposta la supera, e controllare anche servizi non-web: una porta, un nome (DNS) o la raggiungibilità di una macchina (ping). [Uptime](/member/monitoring/monitors)
- **Errori assegnabili a una persona**: da oggi puoi affidare un errore a un membro del team, così si vede a colpo d'occhio chi se ne sta occupando — come già succede per i ticket. [Errori](/member/monitoring/error)
- **Dividere un gruppo di errori che ne contiene due diversi**: capita che problemi diversi finiscano raggruppati insieme e diventino impossibili da seguire. Da riga di comando ora puoi estrarne una parte in un gruppo nuovo, con la sua storia, senza toccare quello di partenza. [Errori](/member/monitoring/error)
- **Regole tue per decidere come si raggruppano gli errori**: se il raggruppamento automatico non rispecchia come ragioni tu, puoi definire per ogni progetto le regole con cui gli errori vengono messi insieme. Si impostano da riga di comando e valgono da subito sui nuovi arrivi. [Errori](/member/monitoring/error)
- **Guidance: riferimenti e procedure per chi lavora, su tre livelli**: puoi raccogliere in un posto solo riferimenti e procedure per chi lavora, a livello di organizzazione, gruppo o progetto: quelli generali si ereditano verso il basso e si possono sostituire o disattivare. [Guidance dell'organizzazione](/member/organization/guidance) ([guida](/member/guides/guidance))
- **Le istruzioni consegnate a chi lavora restano registrate**: quando un ticket viene preso in carico, le indicazioni valide in quel momento vengono fotografate e conservate così com'erano. Se più avanti le cambi, resta comunque tracciato con quali istruzioni quel lavoro è stato fatto. [Ticket](/member/tickets)
- **Le pagine lente si vedono anche quando la media è buona**: accanto al tempo medio ora trovi il tempo della visita tipica e quello delle visite peggiori, così i rallentamenti di pochi non restano invisibili. [Performance](/member/monitoring/performance)
- **Dipendenze tra ticket**: nella pagina di un ticket ora trovi la sezione «Dipendenze», dove indichi con un clic quali altri ticket vanno risolti prima di questo. Sulla bacheca, un ticket in attesa mostra l'etichetta «bloccato», che sparisce da sola appena il prerequisito viene risolto. [Ticket](/member/tickets)

### Fixed

- **Le azioni sulle macchine dicono cosa stanno facendo**: prima sembravano non produrre nulla. Ora la richiesta appare subito in elenco, passa da sola a «in corso» e «completata» con il dettaglio, e la pagina dice quanti aggiornamenti sono di sicurezza. [Macchine](/member/monitoring/servers)
- **I messaggi di conferma non spariscono più prima di essere letti**: sulle pagine che si aggiornano da sole il riquadro di conferma veniva cancellato dopo un paio di secondi. Ora resta il tempo previsto, e il nome digitato per confermare non si cancella più.
- **Assistente più chiaro all'apertura e quando si blocca**: all'apertura propone quattro domande pronte e una riga che dice di cosa si occupa; se non riesce a rispondere spiega se riprovare o riformulare, con il collegamento alle guide. [Guide](/member/guides)
- **Vedi cosa fa ogni macchina, e quando una è ferma**: prima una macchina spenta da giorni sembrava a riposo. Ora la colonna dell'attività dice cosa fa ciascuna, e una macchina senza segnali si accende come allarme e fa partire un avviso. [Agenti](/member/agents)
- **I messaggi si collegano da soli agli errori della stessa richiesta**: aprendo un messaggio vedi quanti altri messaggi ed errori appartengono alla stessa richiesta, con un collegamento per aprirli insieme — anche quando l'identificativo è solo nel testo. [Log](/member/monitoring/logs)
- **Sai subito se i lavori programmati e i siti sono davvero coperti da un avviso**: prima l'avviso promesso senza una regola attiva non poteva arrivare. Ora gli elenchi dicono quanti sono coperti e dove manca la regola c'è il collegamento per crearla. [Lavori programmati](/member/monitoring/cron) · [Uptime](/member/monitoring/monitors)
- **Un nome solo per i segreti dell'organizzazione, e chi li vede a colpo d'occhio**: il nome ora è uno solo ovunque e la pagina iniziale dice chi può vederli e quanti sono; la guida non promette più una visibilità che non c'era. [Vault](/member/vault)
- **Tutto in italiano, anche gli stati e i tempi**: in più punti comparivano parole dal codice e stati in inglese. Ora l'interfaccia è tradotta ovunque e accanto allo stato di un ticket è spiegato il passo successivo. [Ticket](/member/tickets)
- **I numeri degli errori sono leggibili e concordano tra loro**: lo stesso errore mostrava conteggi diversi e su portatile le cifre uscivano dallo schermo. Ora i conteggi sono calcolati allo stesso modo dappertutto e la tabella si adatta agli schermi piccoli. [Errori](/member/monitoring/error)
- **Si vede chi è stato colpito e l'errore si legge per intero**: la colonna delle persone colpite restava vuota e alcuni testi erano oscurati senza spiegazione. Ora la colonna si popola quando l'informazione arriva, e dove il testo è protetto la pagina dice perché. [Errori](/member/monitoring/error)
- **Ordinare dal più lento mostra i rallentamenti veri**: prima in cima finivano casi rari e isolati. Ora l'ordinamento tiene conto di quanto spesso una pagina viene aperta. [Performance](/member/monitoring/performance)
- **Ogni cosa ha un nome solo e una strada di ritorno**: la stessa coda si chiamava in quattro modi e alcune aree non avevano uscita. Ora i nomi sono coerenti tra menu, pagine e guide, e da ogni area si torna indietro. [Home](/member/home)
- **La coda non chiede più decisioni su cose già chiuse**: tra le richieste in attesa comparivano ticket già chiusi, che restavano lì a occupare spazio e a far perdere tempo. Ora spariscono da soli appena vengono chiusi. [Approvazioni](/member/home/approvals)
- **Accettare tante richieste in una volta è più svelto**: accettando in blocco le richieste selezionate, il lavoro per tenere aggiornate le bacheche cresceva con quante ne sceglievi. Ora è lo stesso per una o per venti. [Approvazioni](/member/home/approvals)
- **Di notte gli avvisi importanti arrivano lo stesso**: le ore di silenzio trattenevano anche l'email di un sito caduto nel cuore della notte. Ora il silenzio vale per le segnalazioni che possono aspettare, non per quelle urgenti. [Avvisi](/member/alerting/rules)

## [0.79.0] - 2026-08-09

### Fixed

- **Una lavorazione bocciata non si perde più**: quando il controllo automatico scartava il lavoro, il ticket spariva dalla coda e serviva un intervento a mano. Ora torna in coda da solo e l'agente riprova; dopo due errori di fila si ferma e chiede aiuto. [Ticket](/member/tickets)

### Changed

- **Rifiutare un lavoro ora vuol dire due cose diverse**: puoi rimandarlo all'agente, con le tue note come indicazione per il tentativo successivo, oppure metterlo da parte perché ci guardi una persona. Prima il rifiuto lasciava il ticket in un limbo. [Ticket](/member/tickets)

## [0.78.1] - 2026-08-09

### Fixed

- **La lista delle pagine da archiviare non parte più piena**: nella pagina Revisione comparivano fra le «accettate, non ancora archiviate» tutte le pagine già scritte a mano nel tempo, che non aspettavano niente da nessuno. Ora ci finiscono solo quelle passate davvero da una tua decisione. [Revisione](/member/knowledge/reviews)

## [0.78.0] - 2026-08-09

### Added

- **Revisione della knowledge**: le pagine proposte da un assistente restano in una fila dedicata, fuori da ricerca e risposte, finché non le accetti tu. Quello che scarti resta da parte e non ti viene riproposto. ([guida](/member/guides/knowledge-review)) [Revisione](/member/knowledge/reviews)

## [0.77.5] - 2026-08-09

### Fixed

- **Tutto quello che l'applicazione fa da sola è ripartito**: da giovedì mattina i lavori in sottofondo — controlli, avvisi, email, statistiche — erano fermi senza mostrare alcun errore. Ora riprendono e l'arretrato viene smaltito da solo. [Uptime](/member/monitoring/monitors)

## [0.77.4] - 2026-08-08

### Fixed

- **Il pulsante "Rifiuta" nella scheda del ticket è allineato agli altri**: nella riga dei pulsanti del titolo era visibilmente più alto di "Approva" e degli altri pulsanti accanto. Ora ha la stessa altezza. [Ticket](/member/tickets)

## [0.77.3] - 2026-08-08

### Fixed

- **Un motivo di blocco vuoto non passa più i controlli**: se l'automazione si fermava indicando un motivo fatto di soli spazi, il sito lo accettava ma il programma sulla macchina lo scartava, e la segnalazione spariva. Ora serve un motivo vero da entrambe le parti. [Ticket](/member/tickets)

## [0.77.2] - 2026-08-08

### Fixed

- **Quando il rilascio automatico si ferma, adesso ti dice perché**: il motivo veniva scartato per un dettaglio di formato e non restava traccia. Ora arriva sempre, e un rilascio non può dichiararsi riuscito senza la sua versione. [Ticket](/member/tickets)

## [0.77.1] - 2026-08-07

### Fixed

- **Il lavoro consegnato non va più perso quando i test non si possono eseguire**: un resoconto onesto — «controlli non eseguibili» — veniva scartato e il ticket non arrivava mai alla tua approvazione. Ora quel caso è previsto e il ticket prosegue; un controllo eseguito e fallito continua a fermare tutto. [Ticket](/member/tickets)

## [0.77.0] - 2026-08-07

### Fixed

- **Il lavoro già fatto non viene più rifatto da capo**: quando l'assistente riapriva un ticket già completato, il resoconto veniva scartato e la lavorazione ripartiva da zero. Ora dichiara il lavoro già consegnato e il ticket prosegue verso la tua approvazione. [Ticket](/member/tickets)

## [0.76.1] - 2026-08-07

### Fixed

- **La coda di lavoro degli assistenti si era fermata**: subito dopo l'aggiornamento precedente i progetti smettevano di passare lavoro agli assistenti automatici — invece del ticket successivo la coda risultava non disponibile, e le macchine restavano ferme senza avere niente da fare. [Ticket](/member/tickets)
- **Le domande all'assistente non rallentano più il sito per gli altri**: quando l'assistente era lento, il sito diventava lento per tutti. Ora queste richieste vengono elaborate sullo sfondo: la pagina risponde subito e la risposta compare quando è pronta. [Chiedi ai ticket](/member/tickets/ask)
- **Avvisi quando un contenitore di una macchina si spegne**: prima un contenitore morto spariva dall'elenco senza segnali. Ora la sua scomparsa fa partire un avviso con nome e macchina; se si spengono tutti insieme arriva un unico avviso. [Server](/member/monitoring/servers)
- **I limiti di ricezione dati valgono comunque sia scritto l'indirizzo**: bastava aggiungere pochi caratteri all'indirizzo per aggirarli senza lasciare traccia. Ora il limite vale su ogni forma dell'indirizzo e ogni superamento resta registrato.
- **Quando una macchina si blocca su una lavorazione, ora te ne accorgi**: prima una macchina bloccata sembrava spenta e il guasto durava giorni. Ora segnala il fallimento col motivo, la sua pagina mostra quante lavorazioni fallisce e se sono troppe parte un avviso. [Agenti AI](/member/agents)

## [0.76.0] - 2026-08-06

### Fixed

- **I piani che approvi arrivano davvero a chi scrive il codice**: l'assistente non riusciva a leggere il piano approvato e si fermava. Ora gli arriva per intero, insieme all'incarico. [Ticket](/member/tickets)
- **Avvisi quando una macchina della flotta cade**: prima un server che smetteva di rispondere non faceva partire nessun avviso. Ora caduta e rientro, servizi in errore, dischi che cedono e database irraggiungibili avvisano sui canali configurati, anche per le organizzazioni già esistenti. [Server](/member/monitoring/servers)

## [0.75.0] - 2026-08-06

### Added

- **Chi prende in carico un ticket lo dichiara, e gli altri lo vedono**: la presa in carico ora è esplicita e visibile, uguale per persone e assistenti, e decade da sola se chi l'ha presa sparisce: il ticket torna disponibile. [Ticket](/member/tickets)

### Fixed

- **Togliere una persona dall'organizzazione le toglie davvero l'accesso**: prima spariva solo il nome dall'elenco, mentre collegamenti, permessi e chiavi restavano attivi. Ora la rimozione chiude tutto in una volta. [Membri](/member/members)
- **Chi gestisce le persone non può più darsi da solo l'accesso a tutto**: chi gestiva i membri poteva collegarsi da solo a ogni progetto dell'organizzazione. Ora quella scorciatoia è chiusa. [Membri](/member/members)
- **Il pulsante nelle email di avviso ora apre la pagina giusta**: l'indirizzo del pulsante era scritto in forma incompleta e portava a una pagina inesistente.
- **Da riga di comando la soglia di un avviso non si salva più al contrario**: chiedendo «avvisami solo dai casi gravi in su» si otteneva l'opposto, cioè un avviso per tutto, messaggi di servizio compresi. Ora il valore viene salvato come è stato chiesto.

## [0.74.0] - 2026-08-06

### Added

- **Vedere un tipo di approvazione per volta**: sopra la fila c'è una riga di pulsanti, uno per tipo di richiesta, col numero di quante ne aspettano: ne premi uno e in fila restano solo quelle. Compaiono solo i tipi con qualcosa da fare. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))

### Changed

- **Dal passo alla scheda della macchina**: nella scheda Automazione, il nome della macchina che ha eseguito un passo ora si clicca e porta alla sua pagina. Chi non ha il permesso continua a leggere solo il nome. [Ticket](/member/tickets)

### Fixed

- **Le lavorazioni automatiche arrivano in fondo invece di ricominciare da capo**: un resoconto con una risposta non prevista veniva scartato e il ticket ricominciava da capo, per ore. Ora viene accettato, la lavorazione si chiude con un esito e il ticket avanza. [Ticket](/member/tickets)

## [0.73.0] - 2026-08-06

### Added

- **Lo stato del servizio sul tuo sito**: il pulsante Incorpora di un servizio pubblicato dà due codici pronti da copiare: una striscia piccola con lo stato per le pagine del tuo sito e l'intera pagina di stato dentro una pagina tua. [Uptime](/member/monitoring/monitors) ([guida](/member/guides/uptime))

### Fixed

- **Accettare più approvazioni insieme non si ferma più a metà**: la pagina poteva interrompersi con un errore senza dire quali richieste fossero passate. Ora il riepilogo arriva sempre e se una fallisce le altre proseguono. [Approvazioni](/member/home/approvals)
- **Le pagine aperte reggono il lavoro di più persone insieme**: gli aggiornamenti automatici delle pagine passavano da un archivio interno che sotto sforzo si bloccava. Ora è stato spostato dove il carico di tutti sta senza intralciarsi.

### Security

- **La doppia approvazione dei segreti vale anche da riga di comando**: da lì si potevano cambiare i segreti senza la seconda approvazione richiesta. Ora anche creare, importare o cancellare un segreto da riga di comando resta in attesa di approvazione, come dal web. [Richieste in attesa](/member/vault/requests)

## [0.72.1] - 2026-08-06

### Fixed

- **Le pagine di conoscenza rispettano davvero i permessi**: chi poteva pubblicare su un progetto riusciva a sovrascrivere pagine legate a progetti non suoi. Ora serve il permesso su tutti i progetti collegati, anche per allargarne la portata. [Conoscenza](/member/knowledge/pages)
- **Salvare una vista dalla pagina Idee non dà più errore**: il pulsante per conservare i filtri mostrava sempre una pagina di errore, pur avendo creato la vista; anche cancellarla dal menu falliva allo stesso modo. Ora entrambe le operazioni si concludono normalmente. [Idee](/member/ideas)
- **Un ticket non viene più rifiutato solo perché nomina un server**: bastava citare l'indirizzo di un server o il nome di un archivio dati perché il ticket venisse messo da parte. Ora conta cosa il ticket chiede di fare, non quali nomi contiene.
- **Il monitoraggio regge le segnalazioni compresse costruite per farlo cadere**: le segnalazioni compresse venivano aperte senza controllare quanto diventassero grandi, e poche richieste bastavano a mettere in ginocchio il servizio. Ora l'apertura si ferma appena supera la soglia consentita.
- **Le richieste di modifica da GitHub non generano più errori quando arrivano due volte**: quando la stessa richiesta veniva annunciata più volte nello stesso istante, la registrazione falliva con un errore interno. Ora la seconda notifica aggiorna quella già presente invece di duplicarla.
- **Il sito pubblico non perderà caratteri e icone**: la protezione annunciata sui contenuti esterni non autorizzava le fonti che il sito usa davvero: accendendola sarebbero spariti testo e icone. Ora le fonti legittime sono dichiarate.

## [0.72.0] - 2026-08-06

### Added

- **Accettare più approvazioni in un colpo solo**: ogni riga accettabile così com'è ha una casella: ne spunti quante vuoi, premi Accetta una volta e le smaltisci tutte. Domande e lavorazioni ferme si aprono una per una come prima. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))
## [0.71.0] - 2026-08-05

### Added

- **La pagina di un agente dice cosa ha lavorato e quanto ci mette**: ora mostra anche il lavoro già fatto: quanti ticket lavorati, i tempi, la quota di lavori respinti e l'elenco dei ticket toccati. Un selettore in alto sceglie il periodo. [Agenti](/member/agents)

### Fixed

- **Le lavorazioni col piano pronto si possono approvare di nuovo**: dopo una bocciatura, la lavorazione restava ferma anche col passaggio rifatto e chiuso bene, e i pulsanti per approvare il piano non comparivano. Ora i ticket rimasti indietro tornano approvabili da soli. [Ticket](/member/tickets)
- **Le date non fanno più saltare le pagine a chi usa l'italiano**: chi aveva impostato l'italiano come lingua vedeva un errore su ogni pagina che mostra una data o un orario. Ora le date si leggono nel formato italiano, giorno prima del mese.

### Changed

- **I passi della lavorazione si aprono solo quando servono**: ogni passo ora sta ripiegato su una riga con le informazioni essenziali e si apre con un clic. Restano aperti da soli il passo in corso e l'ultimo bocciato. [Ticket](/member/tickets)
- **La scheda del ticket non ripete più le stesse cose due volte**: alcune informazioni comparivano due volte nella pagina. Ora ognuna sta in un posto solo, e il riquadro "Agenti AI" è quello completo, con motivo, autore e pulsanti della decisione. [Ticket](/member/tickets)

## [0.70.2] - 2026-08-05

### Fixed

- **Anche i vecchi disservizi doppi si chiudono da soli**: quando un sito torna a posto, ora vengono chiuse tutte le segnalazioni di disservizio ancora aperte per quel sito — comprese eventuali doppie rimaste da prima. Così la pagina di stato non mostra più un guasto che non c'è più. [Disponibilità](/member/monitoring/monitors)

## [0.70.1] - 2026-08-05

### Security

- **I file riservati di un ambiente restano fuori portata di chi è limitato a un altro**: una credenziale confinata a un ambiente poteva comunque scaricare o cancellare certificati e chiavi di firma di un altro. Ora il limite vale anche per i file.
- **In tempo reale ognuno riceve solo i dati dei progetti che può vedere**: gli aggiornamenti dal vivo di errori e disponibilità arrivavano al browser di tutta l'organizzazione. Ora restano confinati ai progetti che si possono vedere. [Errori](/member/monitoring/error)
- **Una sessione scaduta non resta più collegata dietro le quinte**: una sessione scaduta o inattiva continuava a ricevere gli aggiornamenti in tempo reale. Ora viene chiusa anche lì.

### Fixed

- **Un sito lento non resta più segnato come guasto per sempre**: un controllo lento poteva aprire due segnalazioni sullo stesso sito e una restava aperta, con avvisi doppi. Ora ne resta sempre una sola. [Disponibilità](/member/monitoring/monitors)
- **Un'ondata di messaggi non blocca più gli avvisi**: tanti messaggi di errore insieme rallentavano tutti gli avvisi. Ora un'ondata viene gestita in un colpo solo.
- **Un indirizzo che non risponde non rallenta più gli altri controlli**: un sito che non rispondeva teneva fermo il controllo senza limite. Ora c'è un tempo massimo di attesa.

## [0.70.0] - 2026-08-05

### Added

- **Il resoconto di lavorazione si legge dal sito**: prima esisteva solo da riga di comando. Ora c'è una scheda Resoconto: si legge formattato, con le stesure precedenti, chi le ha scritte e quando. [Ticket](/member/tickets)

### Changed

- **Le analisi tecniche già scritte prendono la forma nuova**: vengono riorganizzate nelle stesse voci delle analisi nuove, senza aggiungere niente. Il testo di prima resta nella cronologia del ticket. [Ticket](/member/tickets)

### Fixed

- **Le lavorazioni ferme si rimettono in coda con un clic**: il pulsante per rimettere in coda una lavorazione bocciata compariva solo in certi casi e il ticket restava fermo. Ora c'è ogni volta che serve e la lavorazione riparte davvero. [Approvazioni](/member/home/approvals)

## [0.69.0] - 2026-08-05

### Added

- **Una pagina per smaltire in fila tutto quello che aspetta una tua decisione**: analisi, ticket da revisionare, domande e richieste sui dati riservati ora stanno in un posto solo: a sinistra la coda, al centro il testo, a destra i modi di rispondere. Appena decidi, si apre da sola la richiesta dopo. [Approvazioni](/member/home/approvals) ([guida](/member/guides/approvals))
- **I resoconti di lavorazione hanno un posto loro**: il resoconto di fine lavorazione non finisce più nella discussione ma in una sezione dedicata, con lo storico. Se viene rifatto nasce una nuova versione e la precedente resta leggibile. [Ticket](/member/tickets)
- **Ai ticket si possono allegare file markdown**: prima venivano rifiutati senza spiegazione, ed è il formato in cui si scrive un documento tecnico. [Ticket](/member/tickets)
- **L'analisi tecnica dice quanto è lungo il testo giusto**: il contatore ingiallisce a metà strada, così c'è ancora spazio per accorciare. Sotto la casella vuota compaiono le voci da riempire. [Ticket](/member/tickets)
- **I consigli lasciati su un ticket diventano ticket nuovi**: ora hanno un riquadro sulla scheda, e accanto a ognuno un collegamento apre un ticket nuovo già compilato. I due ticket restano legati fra loro. [Ticket](/member/tickets)

### Changed

- **I commenti tornano brevi e leggibili**: un commento ora può essere lungo al massimo quanto un messaggio, e mentre scrivi vedi quanto spazio resta. I commenti lunghi già scritti si spostano nei resoconti, con un riassunto nella discussione. [Ticket](/member/tickets)
- **L'analisi tecnica torna nella scheda del ticket**: le analisi finite nei commenti per mancanza di spazio vengono rimesse insieme in un documento allegato al ticket, con una spiegazione breve nella scheda. I commenti originali restano dove sono. [Ticket](/member/tickets)
- **Le domande dell'assistente non riempiono più la discussione**: quando l'assistente ha bisogno di una risposta, nella discussione resta una riga breve che avvisa; le domande si leggono e si rispondono nella scheda Automazione, dove sono sempre state. [Ticket](/member/tickets)
- **I testi si leggono formattati in tutta l'app**: titoli, elenchi, grassetti, tabelle e codice comparivano coi loro simboli in chiaro. Ora sono resi come si deve ovunque si scriva testo libero, e gli a capo restano dove sono. [Ticket](/member/tickets)

## [0.68.0] - 2026-08-04

### Changed

- **L'analisi tecnica del ticket ha una scheda tutta sua**: prima stava in fondo al dettaglio e diventava un muro di testo. Ora è una scheda a parte e il testo è formattato: titoli, elenchi, tabelle e codice si leggono come tali. [Ticket](/member/tickets)

## [0.67.1] - 2026-08-04

### Changed

- **Da riga di comando le caselle della tabella dicono la piattaforma per nome**: prima, chiedendo le caselle di una funzionalità, la piattaforma compariva solo come codice interno lungo e illeggibile, e per capire di quale si trattasse bisognava confrontarlo a mano con l'elenco delle piattaforme. [Matrice funzionalità](/member/product/matrix)

## [0.67.0] - 2026-08-03

### Added

- **La tabella delle funzionalità si può usare anche da riga di comando**: da terminale ora si può leggere la tabella di un prodotto, aggiungere o rinominare gruppi e funzionalità, e dire a che punto è una funzionalità su una piattaforma. Valgono gli stessi permessi del sito. [Matrice funzionalità](/member/product/matrix) ([guida](/member/guides/feature-matrix))

## [0.66.1] - 2026-08-03

### Security

- **Sulla bacheca vedi solo i tuoi progetti**: quando qualcuno spostava un ticket, la sua scheda arrivava sulla bacheca di tutti, anche di chi non vedeva quel progetto. Ora arriva solo a chi lo vede. [Ticket](/member/tickets)
- **I numeri in cima alle colonne contano solo i tuoi ticket**: dopo uno spostamento, i numeri delle colonne e quelli in cima a Errori, Uptime e Cron mostravano i totali di tutta l'organizzazione. Ora ognuno vede i propri. [Ticket](/member/tickets)

### Changed

- **Le pagine che si aggiornano da sole ora conservano il punto in cui eri**: bacheca ticket, Uptime, Cron e Interruzioni si ricaricano da sole mantenendo lo scorrimento, i filtri impostati e la ricerca in corso. [Uptime](/member/monitoring/monitors)

## [0.66.0] - 2026-08-03

### Added

- **Sai cosa c'è su quale piattaforma**: per ogni prodotto una tabella incrocia funzionalità e piattaforme: per ogni incrocio indichi a che punto sei e da quale versione è disponibile. Le funzionalità stanno in gruppi, e ognuna può rimandare alla pagina che la spiega. [Matrice funzionalità](/member/product/matrix) ([guida](/member/guides/feature-matrix))

## [0.65.0] - 2026-07-31

### Changed

- **I ticket ora hanno i nomi standard**: bug, story, task ed epic. Prima si chiamavano bug, feature e miglioria. Chi apriva ticket con questi nomi da un programma esterno deve usare i nuovi. [Ticket](/member/tickets)
- **Non serve più accendere niente per aprire un ticket**: prima, per aprire qualcosa che non fosse un bug, bisognava prima attivare la roadmap sul progetto, altrimenti il salvataggio falliva. Quel passaggio non c'è più: su ogni progetto puoi aprire subito qualunque tipo di ticket. [Ticket](/member/tickets)
- **La roadmap c'è su tutti i progetti**: milestone e bacheca roadmap ora ci sono sempre, senza interruttore da attivare. Nella bacheca roadmap compaiono epic e story; task e bug restano nella bacheca dei ticket.

### Added

- **Le epic raccolgono gli altri ticket**: un'epic raccoglie ticket dello stesso progetto: sulla sua pagina vedi quali contiene e quanti sono chiusi, sul ticket vedi a quale epic appartiene. Un'epic non può stare dentro un'altra epic. [Ticket](/member/tickets) ([guida](/member/guides/tickets))

## [0.64.2] - 2026-07-31

### Security

- **Se la copia di sicurezza smette di essere fatta, te ne accorgi**: a ogni copia riuscita il sistema manda un segnale di vita; se non arriva entro il tempo previsto, ricevi un avviso.

## [0.64.1] - 2026-07-31

### Security

- **I tuoi dati ora hanno una copia di sicurezza**: ogni notte una copia completa dei dati viene salvata in un archivio esterno e conservata per trenta giorni. Le copie non si possono cancellare, nemmeno entrando nel server: si può solo aggiungerne.

## [0.64.0] - 2026-07-31

### Added

- **Sul ticket si vede cosa sta facendo l'assistente**: la pagina del ticket ora ha tre schede: Dettaglio, Automazione e Discussione. In Automazione c'è tutto il lavoro dell'assistente passo per passo, compresi i tentativi andati male. [Ticket](/member/tickets)
- **Alle domande dell'assistente si risponde dal ticket**: ogni domanda ora ha il suo spazio per la risposta, invece di un commento scritto a mano. Le risposte diventano un unico commento e la lavorazione riparte da sola. [Ticket](/member/tickets)

### Fixed

- **L'assistente non rifà più lo stesso piano all'infinito**: quando il piano veniva bocciato, l'assistente lo rifaceva senza limite e senza che si vedesse da nessuna parte. Ora dopo due bocciature la lavorazione si ferma e aspetta che decida una persona. [Ticket](/member/tickets)

## [0.63.1] - 2026-07-30

### Fixed

- **Durante una raffica anche il secondo meccanismo smette di scrivere**: anche l'aggiornamento automatico delle pagine scriveva un segnale a ogni ripetizione di un errore, peggiorando la raffica. Ora, finché la raffica dura, quel lavoro si fa una volta ogni cento ripetizioni e le pagine continuano ad aggiornarsi. [Errori](/member/monitoring/error)
- **La pagina di un ticket si apre anche mentre una macchina ci sta lavorando**: finiva in errore proprio in quel momento. Ora si apre e il riquadro dice quale macchina lo sta lavorando e in che fase. [Ticket](/member/tickets)

## [0.63.0] - 2026-07-30

### Fixed

- **Le domande dell'assistente arrivano sul ticket**: restavano registrate dentro il sistema senza mai comparire sul ticket, e la lavorazione restava ferma. Ora le pubblica il sistema e chi segue il ticket viene avvisato: basta rispondere con un commento e la lavorazione riprende. [Ticket](/member/tickets)

## [0.62.0] - 2026-07-30

### Fixed

- **Gli assistenti possono finalmente fare il lavoro che gli viene chiesto**: la prima fase girava in una modalità che le impediva di eseguire i comandi, quindi nessuna lavorazione automatica si era mai conclusa. Ora esegue davvero, ma ogni tentativo di modificare i file resta bloccato come prima. [Assistenti](/member/agents)
- **Se un sito va giù, ora vieni avvisato**: un sito che cadeva finiva sulla pagina di stato ma non mandava avvisi al team. Ora c'è di serie un avviso quando un sito diventa irraggiungibile e uno quando torna online; puoi rinominarli o spegnerli. [Disponibilità](/member/monitoring/monitors) · [Avvisi](/member/alerting/rules)

### Security

- **Aprire un segreto dal sito ora lascia traccia**: guardare o copiare un segreto dal sito non lasciava traccia, e in alcuni casi il valore era già dentro la pagina. Ora il valore arriva solo quando lo chiedi e ogni accesso resta nel registro. [Secret personali](/member/personal/secrets)

## [0.61.0] - 2026-07-30

### Fixed

- **Se il controllo dei servizi si ferma, ora te ne accorgi**: se la parte che esegue i controlli si fermava, tutto restava verde per sempre. Ora un esito non aggiornato viene mostrato come «sconosciuto», e un nuovo segnale permette a una sorveglianza esterna di accorgersi del blocco. [Disponibilità](/member/monitoring/monitors)
- **Gli avvisi che scattano di notte non vengono più persi**: gli avvisi arrivati durante le ore di silenzio venivano buttati via. Ora vengono tenuti da parte e arrivano in un unico riepilogo appena il silenzio finisce. [Preferenze di notifica](/member/preferences/notifications)
- **I ticket rimasti a metà rientrano in lavorazione**: un ticket preso in carico e poi interrotto restava segnato come «già iniziato» e non veniva più proposto a nessuno. Ora quel segno viene tolto e il ticket torna in fila. [Assistenti](/member/agents)

## [0.60.0] - 2026-07-30

### Changed

- **Una raffica di segnalazioni identiche non riempie più il disco**: una segnalazione ripetuta decine di migliaia di volte riempiva il disco di dettagli tecnici. Ora oltre le prime cinquemila ripetizioni resta solo la riga essenziale; conteggi, grafici ed elenchi non cambiano, e lo stesso vale per i rallentamenti. [Errori](/member/monitoring/error) · [Rallentamenti](/member/monitoring/performance)

### Fixed

- **Una lavorazione interrotta non resta "in corso" per sempre**: una lavorazione senza consegna restava segnata come in corso e poteva impedire di riprovare il ticket. Ora un controllo ogni cinque minuti chiude quelle scadute, conservando quello che l'assistente ha prodotto. [Assistenti](/member/agents)
- **Accorgersi di una raffica non la peggiora più**: il controllo che nota un'impennata di un errore scriveva un segnale a ogni ripetizione, alimentando il problema che doveva segnalare. Ora durante una raffica smette e riprende appena finisce.

## [0.59.4] - 2026-07-29

### Fixed

- **I rallentamenti e gli errori non occupano più il doppio dello spazio**: ogni segnalazione veniva conservata in due copie identiche, occupando spazio inutile. Ora se ne conserva una sola e le pagine mostrano le stesse informazioni di prima. [Rallentamenti](/member/monitoring/performance) · [Errori](/member/monitoring/error)

## [0.59.3] - 2026-07-29

### Fixed

- **Gli aggiornamenti automatici delle pagine non si accumulano più**: il lavoro che ricarica una pagina veniva rimesso in lista all'infinito quando gli eventi erano fitti. Ora ne resta uno solo finché non è eseguito, e le pagine si aggiornano come prima.

## [0.59.2] - 2026-07-29

### Fixed

- **La ricerca per significato è tornata a funzionare**: dal 28 luglio il collegamento col servizio che capisce il senso dei testi era caduto in silenzio: ricerca per significato, ticket doppi e domande in linguaggio naturale non funzionavano. Ora è ripristinato e i dati di quei due giorni vengono recuperati. [Ticket](/member/tickets) · [Conoscenza](/member/knowledge/pages)
- **L'elenco dei lavori falliti mostra solo i problemi veri**: i lavori falliti restavano in elenco per sempre, quasi tutti legati a un guasto già risolto. Ora le righe più vecchie di una settimana vengono tolte da sole ogni notte.
- **Il programma non fa più due volte lo stesso lavoro di sottofondo**: la parte che risponde alle pagine web eseguiva anche i lavori in sottofondo, facendo tutto in doppio. Ora ognuno fa il proprio mestiere.
- **Anche l'ambiente di prova ha le sue chiavi**: la ricerca per significato e l'assistente non funzionavano nell'ambiente di prova perché mancavano due chiavi. Ora arrivano, e un controllo automatico evita che succeda di nuovo.

## [0.59.1] - 2026-07-29

### Fixed

- **Il controllo di disponibilità non si ferma più se cambi le impostazioni del progetto**: bastava togliere una piattaforma o un ambiente dal progetto perché il controllo smettesse di salvare gli esiti, senza avvisi. Ora i requisiti valgono solo quando crei il controllo o lo sposti. [Disponibilità](/member/monitoring/monitors)

## [0.59.0] - 2026-07-29

### Added

- **Interruttori per le funzioni AI**: nelle impostazioni di sistema c'è un interruttore per ogni funzione che usa l'intelligenza artificiale: si spengono e riaccendono con un clic e valgono subito. Serve per fermare in fretta una funzione che dà problemi. [Impostazioni](/valhalla/settings)

### Fixed

- **Il monitoraggio non si segnala più da solo**: registrare l'errore del monitoraggio faceva scattare un nuovo errore, in un giro senza fine che riempiva il server. Ora quel tipo di errore non viene più segnalato a sé stessi.

### Changed

- **Il controllo dei ticket costa meno**: la verifica che decide se un ticket può essere lavorato da un assistente ora usa un modello più leggero. Il compito è classificare un rischio, non scrivere testo, quindi il risultato non cambia mentre la spesa scende di cinque volte.

## [0.58.3] - 2026-07-29

### Fixed

- **La ricerca per codice trova anche chi lo cita nell'analisi tecnica**: è il posto dove i codici vengono nominati più spesso, ma la ricerca guardava solo titolo e descrizione, quindi la maggior parte dei riferimenti restava invisibile. [Ticket](/member/tickets)

## [0.58.2] - 2026-07-29

### Fixed

- **La ricerca per codice non perde più ticket con allegati**: un ticket che nomina il codice cercato e ha più file allegati veniva contato una volta per ogni file, occupando i posti riservati agli altri e facendone sparire alcuni dall'elenco. [Ticket](/member/tickets)

## [0.58.1] - 2026-07-29

### Fixed

- **La ricerca per codice restituisce sempre lo stesso elenco**: quando un codice è nominato da moltissimi ticket, l'elenco veniva tagliato senza un criterio, quindi due ricerche identiche potevano mostrare risultati diversi. Ora i ticket che nominano un codice compaiono dai più recenti, e il taglio è sempre lo stesso. [Ticket](/member/tickets)

## [0.58.0] - 2026-07-29

### Added

- **Trovi un ticket scrivendo il suo codice**: scrivendo un codice come `ALEX-3` nella barra di ricerca, quel ticket compare per primo e sotto trovi i ticket che lo nominano. Funziona in bacheca, elenco e roadmap. [Ticket](/member/tickets)

### Changed

- **Il filtro sugli assistenti c'è anche nella bacheca**: prima si poteva scegliere quali ticket mostrare in base a chi può lavorarli — un assistente o una persona — soltanto nella vista a elenco. Ora la stessa scelta è disponibile anche nella bacheca a colonne, dal menu «Filtri». [Ticket](/member/tickets)

## [0.57.0] - 2026-07-29

### Changed

- **Le copie dei database vengono riconosciute con certezza**: prima si indovinava confrontando gli elenchi dei database, e a volte sbagliava. Ora ogni macchina riporta il codice del suo gruppo, uguale sull'originale e sulle copie; serve il programma aggiornato su quelle macchine. [Database](/member/monitoring/databases)

## [0.56.0] - 2026-07-29

### Added

- **Si vede subito quali ticket può prendere in carico un assistente**: accanto al codice del ticket compare un piccolo robot, ovunque il ticket sia elencato: verde se un assistente può lavorarlo, arancione se va ancora esaminato, grigio se serve una persona. Passandoci sopra col mouse leggi la spiegazione. [Ticket](/member/tickets)

## [0.55.1] - 2026-07-29

### Fixed
- **Il sito si apre anche scrivendo l'indirizzo senza «www»**: chi digitava `closeyour.it` senza il prefisso trovava un errore di sicurezza del browser invece del sito. Ora l'indirizzo funziona e porta dove deve, come prima.
## [0.55.0] - 2026-07-29

### Added

- **Ogni database ha la sua pagina**: dall'elenco dei database clicchi il nome e si apre il dettaglio: spazio occupato, crescita nel tempo, macchine che lo ospitano e tabelle più grandi. [Database](/member/monitoring/databases)

## [0.54.0] - 2026-07-29

### Changed

- **L'esame dei ticket non si ferma più dopo pochi al giorno**: i ticket di solo testo passano ora da un servizio senza limiti giornalieri; quelli con immagini restano al servizio che le sa leggere. Il giudizio non cambia. [Ticket](/member/tickets)

## [0.53.1] - 2026-07-29

### Fixed

- **Nell'elenco dei database spariscono i doppioni**: le copie di riserva facevano comparire ogni database due volte, raddoppiando lo spazio totale. Ora ogni database ha una riga sola, con indicate le sue copie. [Database](/member/monitoring/databases)

## [0.53.0] - 2026-07-29

### Added

- **Tutti i database in una pagina sola**: un elenco unico mostra ogni database, il server che lo ospita e lo spazio usato, con ricerca, filtri e ordinamento per peso. La stessa lista è anche nella pagina di ogni server. [Database](/member/monitoring/databases)

## [0.52.0] - 2026-07-29

### Fixed

- **L'esame automatico dei ticket non si intasa più da solo**: le richieste al servizio di intelligenza artificiale partivano tutte insieme e venivano rifiutate. Ora sono distribuite nel tempo e ritentate più tardi. [Ticket](/member/tickets)

## [0.51.1] - 2026-07-29

### Fixed

- **L'assistente di aiuto risponde di nuovo**: la chiave che gli serve per funzionare non arrivava fino al programma pubblicato, e ogni domanda restava senza risposta. Ora arriva. ([Assistente](/member/home))

## [0.51.0] - 2026-07-29

### Fixed

- **L'assistente di aiuto torna a rispondere**: la chiave che permette all'assistente di parlare era rimasta vuota, quindi ogni domanda restava senza risposta. Ora è di nuovo a posto. ([Assistente](/member/home))
- **Le password e le chiavi salvate nella cassaforte arrivano davvero dove servono**: una nota scritta di fianco a una riga della configurazione interrompeva l'invio delle chiavi senza avvisare. Ora le note non danno più fastidio. [Secret](/member/personal/secrets)

## [0.50.0] - 2026-07-29

### Added

- **Decidi tu quali ticket possono lavorare gli agenti**: ogni ticket viene prima esaminato, allegati compresi, e solo quelli sicuri arrivano agli agenti automatici; gli altri restano a te, col motivo scritto. Dalla pagina del ticket puoi sempre decidere diversamente. [Ticket](/member/tickets)

## [0.49.0] - 2026-07-29

### Added

- **Nella pagina di un computer collegato si vede a che punto è il lavoro**: per ogni ticket in lavorazione vedi i passaggi conclusi, quello in corso e i prossimi, con piano, tentativi, ramo di lavoro e proposta di modifica. [Agenti](/member/agents)

## [0.48.1] - 2026-07-28

### Fixed

- **Un computer collegato risultava sempre spento, anche mentre lavorava**: il segnale periodico con cui la macchina dice «ci sono» veniva rifiutato, così la pagina la mostrava spenta anche mentre lavorava. Ora il segnale è accettato e attribuito alla macchina giusta. [Agenti](/member/agents)

## [0.48.0] - 2026-07-28

### Added

- **Stato dei database nei server monitorati**: se un server ospita un database, ora nel suo dettaglio vedi se risponde, quante connessioni ha aperte, se la replica è allineata e quanto è grande. Ricevi anche un avviso se il database smette di rispondere, ha troppe connessioni o la replica va in ritardo. [Server](/member/monitoring/servers)

## [0.47.0] - 2026-07-28

### Changed

- **Un agente è il computer collegato**: nella pagina [Agenti](/member/agents) un agente è il computer che prende in carico un ticket e lo lavora. Le vecchie schede agente da configurare a parte non ci sono più: colleghi il computer, gli dai il via libera e lavora.

### Removed

- **Comandi da terminale per le vecchie schede agente**: i comandi che creavano, modificavano e cancellavano le schede agente sono stati tolti, insieme a tutto quello che le riguardava. Restano i comandi per i codici di accesso dei computer collegati.

## [0.45.0] - 2026-07-28

### Changed

- **Nuovo spazio Product**: Knowledge e Book hanno ora uno spazio dedicato nel menu in alto, pensato per la documentazione di prodotto. Le ritrovi tutte lì, riunite in un unico posto, con Book raggiungibile direttamente dal menu. [Knowledge](/member/knowledge/pages)

## [0.44.0] - 2026-07-27

### Added

- **Azioni rapide dalla home**: dalla [home](/) ora agisci al volo, senza aprire le pagine — approvi o rifiuti (indicando il motivo), rispondi ai commenti e alle menzioni con una casella, e voti le idee. Le tre liste sono anche affiancate a colonne, così vedi tutto in un colpo d'occhio.

## [0.43.0] - 2026-07-27

### Added

- **File allegati alle pagine di conoscenza**: a ogni pagina della knowledge base puoi allegare più file — documenti, immagini, archivi, script — da rinominare, descrivere e scaricare. I file vengono solo conservati, mai aperti o eseguiti. [Knowledge](/member/knowledge/pages)

## [0.42.1] - 2026-07-27

### Changed

- **Home rinnovata**: la [home](/) ora mette in primo piano le cose che aspettano una tua mossa — approvazioni da dare, conversazioni a cui rispondere e idee ancora aperte — al posto delle tabelle di progetti ed errori. Così sblocchi le lavorazioni ferme direttamente dalla prima pagina.

## [0.41.0] - 2026-07-27

### Added

- **Pagine di conoscenza su più progetti, gruppi ed etichette**: una pagina della knowledge base si può ora collegare a più progetti o gruppi, o valere per tutta l'organizzazione. Puoi anche darle etichette libere e filtrare l'elenco per argomento. [Knowledge](/member/knowledge/pages)

## [0.40.3] - 2026-07-26

### Fixed

- **Verifica in due passaggi più comoda**: le sue pagine ora hanno la barra in alto, così dopo la configurazione torni all'app con un clic.

## [0.40.2] - 2026-07-26

### Fixed

- **Ricerca progetti**: risolto un errore che compariva cercando un progetto mentre la lista era ordinata per gruppo. [Progetti](/member/projects)

## [0.40.1] - 2026-07-26

### Added

- **Verifica in due passaggi**: puoi proteggere l'accesso con un secondo codice usa-e-getta generato da un'app di autenticazione, più una serie di codici di recupero da conservare per le emergenze. La attivi da [Verifica in due passaggi](/account/2fa).

### Security

- **Le sessioni ora scadono**: l'accesso resta valido per un periodo limitato e si chiude da solo dopo una lunga inattività, così una sessione dimenticata su un dispositivo non resta aperta per sempre.
- **Cambio password più protetto**: quando cambi la password, l'accesso su tutti gli altri dispositivi viene chiuso.

## [0.39.0] - 2026-07-26

### Fixed

- **Ricerca per significato più affidabile durante gli aggiornamenti**: mentre il sistema ricalcola l'indice della ricerca intelligente, i risultati non mescolano più versioni diverse dei dati — la ricerca resta corretta, al più mostra qualcosa in meno finché il ricalcolo non è finito.

## [0.38.1] - 2026-07-26

### Security

- **Permessi più sicuri**: chi gestisce i membri non può più assegnare — a sé stesso o ad altri — permessi o ruoli più alti di quelli che possiede già.

## [0.37.0] - 2026-07-26

### Fixed

- **Statistiche del sito più robuste**: certe visite con caratteri speciali insoliti nell'indirizzo potevano far scartare un intero blocco di dati delle statistiche; ora vengono ripuliti e i dati si salvano sempre.
- **Invitare chi ha già un account**: se inviti una persona che possiede già un account, ora viene aggiunta all'organizzazione — le basta accedere — invece di ricevere un errore che la bloccava fuori.

## [0.36.0] - 2026-07-26

### Removed

- **Collega il tuo agente AI**: la pagina che spiegava come collegare il tuo assistente AI è stata rimossa.

## [0.35.1] - 2026-07-26

### Fixed

- **Scaricare un file segreto**: ora quando scarichi un file segreto ricevi sempre il suo contenuto completo, invece del file vuoto che poteva capitare prima.
- **Menu delle azioni nelle tabelle**: nelle pagine a elenco (Piattaforme, Ambienti, Ruoli, Traguardi, Team, Documenti) il menu con i tre puntini non viene più tagliato dal bordo — tutte le voci restano visibili e cliccabili.
- **Modificare gli scenari e le condizioni di un [ticket](/member/tickets)**: ora quando cambi gli scenari o le condizioni di completamento di un ticket già esistente, quelli nuovi **sostituiscono** i precedenti invece di aggiungersi. Prima restavano affiancati in doppia copia e non si potevano togliere.
- **Campanella delle notifiche**: corretto un piccolo spazio di troppo accanto all'icona della campanella nella barra in alto.

## [0.34.0] - 2026-07-25

### Added

- **Pagine e ticket più corti, e finalmente cercabili per intero**: il testo delle pagine della [Knowledge base](/member/knowledge/pages) e dei [ticket](/member/tickets) ha ora un tetto di caratteri, con un contatore mentre scrivi. Così entrano tutti nella ricerca, che prima ignorava la parte finale di quelli lunghi ([guida](/member/guides/knowledge)).

## [0.33.0] - 2026-07-25

### Added

- **Pagine collegate tra loro**: in una pagina della [Knowledge base](/member/knowledge/pages) puoi rimandare a un'altra col titolo tra doppie parentesi quadre: al salvataggio diventa un collegamento cliccabile. Ogni pagina mostra a lato cosa collega e chi la cita ([guida](/member/guides/knowledge)).
- **Cosa leggere dopo**: chiedendo una pagina da riga di comando puoi ora ricevere anche le pagine collegate e vicine per argomento, in ordine di pertinenza.

## [0.32.0] - 2026-07-24

### Added

- **Knowledge base**: ogni pagina può ora avere una **sezione tecnica** separata dal testo semplice, con un interruttore per passare tra le due viste. I dettagli tecnici restano cercabili come il resto.

### Security

- Aggiornati **loofah** (2.25.2) e **rails-html-sanitizer** (1.7.1) per risolvere gli avvisi di sicurezza sulla sanificazione dei contenuti HTML.

## [0.31.0] - 2026-07-24

### Changed

- **Automazione ticket**: i computer che eseguono le automazioni ora si collegano con un'identità dedicata e un accesso limitato ai soli ambienti scelti, al posto di una chiave condivisa.

## [0.30.0] - 2026-07-23

### Changed

- **Agenti**: la pagina [Agenti](/member/agents) ora mostra i computer che eseguono le automazioni e cosa stanno facendo in tempo reale, al posto del vecchio elenco tecnico — è più semplice capire chi è attivo e quali attività sono in corso.
- **Automazione ticket**: il motore che lavora i ticket in automatico è stato reso più solido e coerente dietro le quinte, in preparazione della prossima attivazione sui computer dedicati.

## [0.29.8] - 2026-07-18

### Fixed

- **Assistente**: gestione più robusta quando il collegamento al servizio AI non è configurato correttamente — ora il problema viene segnalato e registrato in modo chiaro, invece di limitarsi a non rispondere.

## [0.29.7] - 2026-07-18

### Fixed

- **Assistente**: la risposta compare sempre in modo affidabile, anche con connessioni lente — non resta più bloccata su "sto scrivendo".

## [0.29.6] - 2026-07-17

### Fixed

- **Assistente**: corretto un caso in cui non suggeriva la sezione Agenti a chi ha il permesso di gestirla ma non quello di sola lettura.

## [0.29.5] - 2026-07-17

### Fixed

- **Assistente**: la risposta non resta più bloccata su "sto scrivendo" quando arriva molto in fretta, e su smartphone il pulsante non si sovrappone più alla barra di navigazione in basso.

## [0.29.4] - 2026-07-17

### Fixed

- **Assistente**: suggerisce anche le aree che puoi gestire (non solo quelle in sola lettura), gestisce meglio più domande ravvicinate nella stessa conversazione, e su smartphone il pulsante non copre più la casella di invio.

## [0.29.3] - 2026-07-17

### Fixed

- **Assistente**: i collegamenti alle pagine indicate nelle risposte ora sono cliccabili, e le risposte rispettano la tua lingua.

## [0.29.2] - 2026-07-17

### Fixed

- **Assistente**: ora risponde in modo affidabile alle tue domande, e il pannello della chat resta leggibile e scorrevole anche nelle conversazioni lunghe.

## [0.29.1] - 2026-07-17

### Fixed

- **Automazione ticket**: un ticket approvato per la lavorazione automatica poteva restare in attesa quando gli agenti automatici non erano davvero pronti. Ora in quel caso viene chiuso normalmente.

## [0.29.0] - 2026-07-17

### Added

- **Assistente**: un nuovo pulsante in basso a destra apre una chat: scrivi cosa vorresti fare e l'assistente ti indica lo strumento giusto, con un collegamento alla pagina. La conversazione resta in memoria, così puoi fare domande di seguito.

## [0.28.0] - 2026-07-17

### Added

- **Rollback del pacchetto di skill**: dalla pagina Skill bundle puoi ora consentire di proposito il ritorno a una versione più vecchia, con una spunta dedicata; di default resta bloccato per evitare errori. [Skill bundle](/member/skills)

## [0.27.0] - 2026-07-17

### Added

- **Approvazione a due sui segreti**: ogni progetto può ora richiedere che le modifiche ai segreti degli ambienti protetti siano approvate da un secondo responsabile prima di essere applicate. Ricevi una notifica quando c'è qualcosa da decidere. [Vault](/member/vault)
## [0.26.0] - 2026-07-17

### Changed

- **Skill bundle più sicuro**: la versione del pacchetto di skill che gli host clonano non può più tornare per errore a una versione più vecchia di quella già attiva (un ritorno voluto resta possibile con un'azione esplicita). [Skill bundle](/member/skills)

## [0.25.0] - 2026-07-17

### Added

- **Pacchetto di skill degli agenti**: una nuova pagina in Automazione dove imposti quale versione del pacchetto di skill gli agenti automatici usano, con la possibilità di forzarla a mano. [Skill bundle](/member/skills)
- **Approvazione degli agenti installati**: dalla pagina di un agente installato puoi certificarlo (dare il via libera) o togliergli il via libera, così solo i computer che approvi eseguono lavoro automatico.

## [0.24.0] - 2026-07-17

### Added

- **Spazio preferito**: scegli lo spazio da cui partire con la stellina nel menu degli spazi in alto; all'apertura ti ritrovi subito lì. Le organizzazioni possono impostare uno spazio predefinito per chi non ne ha scelto uno.

## [0.23.0] - 2026-07-17

### Added

- **Scadenza e rotazione dei segreti**: ora puoi dare a un segreto una scadenza di rotazione ("da rinnovare ogni N giorni"). Il Vault evidenzia i segreti in scadenza o già scaduti, ha una pagina che elenca cosa va rinnovato e ti manda un promemoria automatico quando si avvicina il momento. [Vault](/member/vault)
- **Avvisi sui segreti sensibili**: ricevi una notifica quando un segreto viene cancellato o quando la sincronizzazione dei segreti verso GitHub non riesce, così te ne accorgi subito. [Vault](/member/vault)

## [0.22.0] - 2026-07-16

### Added

- **Copia una variabile tra ambienti**: dalla pagina delle variabili segrete di un progetto copi il valore in un altro ambiente con un clic, senza doverlo reinserire a mano. [Vault](/member/vault)
- **Salute del Vault**: una nuova pagina mostra a colpo d'occhio le anomalie delle variabili segrete di tutti i tuoi progetti — condivisioni non più valide, variabili presenti in un ambiente ma mancanti in un altro, e ambienti rimasti senza variabili. [Vault](/member/vault)

## [0.21.0] - 2026-07-16

### Added

- **Buchi tra ambienti evidenziati**: nella pagina dei secret di un progetto, una variabile presente in un ambiente ma mancante in un altro viene ora evidenziata, con un conteggio in cima — così vedi a colpo d'occhio cosa manca dove.
- **Ricerca delle variabili tra progetti**: una nuova pagina nel [Vault](/member/vault) ti fa cercare un nome di variabile e scoprire in quali progetti e ambienti è usato, senza mostrarne i valori.

### Changed

- **Menu riorganizzato**: le voci di Prodotto — ticket, roadmap, idee, knowledge e workload — si trovano ora nell'area Applicazioni del menu, per raggiungerle più in fretta.

## [0.20.0] - 2026-07-16

### Added

- **Attività del Vault**: una nuova pagina raccoglie tutte le operazioni sui segreti — chi ha letto, modificato o sincronizzato una variabile o un file — con filtri per persona, tipo di azione, ambiente e periodo. La trovi nella sezione Attività del [Vault](/member/vault).
- **Cruscotto del Vault**: entrando nel [Vault](/member/vault) trovi ora un riepilogo in cima, con i conteggi e le ultime attività sui segreti, non più soltanto i collegamenti.
- **Storico dei file segreti condivisi**: i file segreti dell'organizzazione ora hanno lo storico delle versioni — come già i file di progetto e personali — e puoi ripristinare una versione precedente.

### Changed

- **Menu organizzato per aree**: la navigazione è ora divisa in aree tematiche — osservabilità, infrastruttura, applicazioni, prodotto, automazione e altre — che scegli dal selettore in alto, per raggiungere più in fretta la sezione che ti serve.

## [0.19.1] - 2026-07-16

### Changed

- **Segreti solo nel Vault**: i collegamenti ai segreti sono stati tolti dal menu principale. Ora variabili e file segreti si gestiscono da un unico posto, entrando nello spazio [Vault](/member/vault) dal selettore in alto.

## [0.19.0] - 2026-07-16

### Added

- **Vault, un unico spazio per i segreti**: tutti i segreti — variabili e file — ora si gestiscono da un unico posto. In alto, accanto all'organizzazione, un nuovo selettore di spazio apre il [Vault](/member/vault), dove trovi i segreti Personali, dell'Organizzazione e di Progetto, sia le variabili sia i file. ([guida](/member/guides/vault))
- **File segreti personali**: oltre alle variabili personali, ora puoi caricare anche i tuoi file segreti privati (chiavi, certificati, credenziali). Restano cifrati e visibili solo a te.

## [0.18.0] - 2026-07-16

### Added

- **Configurazione automatica delle macchine worker**: una macchina che esegue le automazioni può chiedere al sistema quali progetti gestire e prepararsi da sola, senza configurazione manuale progetto per progetto.
- **Macchine worker certificate**: una macchina riceve ticket da lavorare solo dopo essere stata certificata e finché ha capacità libera, per un controllo più sicuro della flotta.

## [0.17.1] - 2026-07-15

### Fixed

- **Attivazione delle automazioni**: la configurazione iniziale degli agenti ora si completa correttamente anche nelle organizzazioni che avevano già agenti configurati.

## [0.17.0] - 2026-07-15

### Added

- **Agents & Commands Manager**: crea comandi organizzativi con istruzioni testuali e assegna a ogni agente soltanto i progetti autorizzati dalla pagina [Agents](/member/agents).
- **Workflow automatico dei ticket**: i nuovi ticket possono essere analizzati, chiariti, pianificati, approvati dal CTO e consegnati alla revisione umana mantenendo visibile ogni passaggio.
- **Installazioni Automator sotto controllo**: vedi quali server e Mac sono online, quale agente stanno eseguendo e quando hanno inviato l'ultimo segnale.

### Changed

- **Automazioni più sicure**: gli agenti eseguono soltanto comandi registrati e ogni risultato viene controllato da un secondo runtime prima di produrre effetti.
- **Approvazione dei piani**: il CTO dell'organizzazione, oppure quello scelto per il progetto, è l'unica persona che può approvare un piano o richiedere modifiche.

## [0.16.0] - 2026-07-14

### Added

- **Installazioni Automator identificabili e revocabili**: ogni dispositivo registra un host dedicato, usa un proprio token e invia heartbeat e telemetria verificabili.
- **Esecuzioni coordinate dal server**: lease, limiti di concorrenza e budget vengono assegnati in modo atomico e restano corretti anche con più dispositivi o processi concorrenti.
- **Coda ticket autoritativa**: Automator può selezionare, prenotare e differire il prossimo ticket idoneo tramite selezioni firmate e scadenze decise dal server.
- **Pubblicazione Knowledge idempotente**: le pagine prodotte dagli agenti possono essere pubblicate da CLI senza duplicati, anche dopo retry concorrenti.

### Changed

- **Autenticazione Automator più stretta**: il token organizzazione serve solo all'enrollment; tutte le operazioni successive richiedono il token dell'host registrato.

## [0.15.3] - 2026-07-14

### Changed

- **Elenco secret da terminale**: l'elenco dei secret è servito in modo paginato e sicuro; lo strumento a riga di comando aggiornato mostra sempre l'elenco completo.

## [0.15.0] - 2026-07-13

### Added

- **Attiva il push dei secret da riga di comando**: ora si può attivare o disattivare da CLI la sincronizzazione dei secret del vault verso i GitHub Environment (prima possibile solo dalla scheda web del progetto), utile per configurare più progetti in serie; lo stato è anche esposto nell'output. (CYCL-3)

## [0.14.0] - 2026-07-13

### Added

- **Secret anche per gli ambienti di anteprima**: i secret del vault ora si sincronizzano anche sull'ambiente GitHub «preview», oltre a produzione e staging. Serve agli ambienti di anteprima creati per ogni proposta di modifica. Scegli l'environment di anteprima dalla scheda GitHub del progetto.

## [0.13.3] - 2026-07-12

### Fixed

- **Controlli completi dopo il rilascio**: smoke test e passaggio in produzione vengono eseguiti
  anche quando la suite principale è stata distribuita su più esecutori.

## [0.13.2] - 2026-07-12

### Fixed

- **Rilascio dopo le verifiche parallele**: una verifica completata con successo ora prosegue
  correttamente verso l'ambiente di prova e la produzione.

## [0.13.1] - 2026-07-12

### Fixed

- **Verifiche automatiche più affidabili**: eliminata una collisione casuale nei dati di test che
  poteva fermare una release anche quando l'applicazione funzionava correttamente.

## [0.13.0] - 2026-07-12

### Changed

- **Verifiche automatiche più rapide**: i controlli completi vengono distribuiti su più esecutori,
  riducendo l'attesa prima di integrare e rilasciare una modifica senza rinunciare ai controlli sui
  test e sulla copertura del codice.

## [0.11.0] - 2026-07-12

### Added

- **Token distribuiti senza mostrarli**: le automazioni possono creare un token di monitoraggio e
  consegnarlo direttamente allo spazio sicuro del progetto, senza leggerne il valore. La distribuzione
  può essere ripresa se GitHub non risponde e richiede una conferma aggiuntiva per la produzione.
- **Collega il tuo agente AI**: una nuova pagina ti guida a far usare al tuo assistente AI (come Claude Code o Codex) lo strumento da riga di comando di CloseYourIt, con le istruzioni pronte da copiare e già personalizzate con i tuoi progetti.

### Changed

- **Novità più chiare**: la lista delle novità è ora scritta in modo semplice e senza tecnicismi, con link diretti alle pagine e alle [guide](/member/guides) delle funzionalità.

## [0.10.0] - 2026-07-12

### Added

- **Secret personali**: ogni persona ha un proprio spazio sicuro dove custodire valori riservati, distinto per organizzazione e usabile sia dall'app sia da riga di comando. I valori sono cifrati, ne resta uno storico ripristinabile e ciascuno vede solo i propri. Apri i [Secret personali](/member/personal/secrets).

## [0.9.1] - 2026-07-12

### Fixed

- **Grafici del monitoraggio più precisi**: cliccando su una barra del grafico di errori e metriche ora vedi esattamente gli elementi di quel periodo, senza più intervalli che sembravano pieni ma risultavano vuoti nell'elenco.

## [0.9.0] - 2026-07-12

### Changed

- **Aggiunta secret più ordinata**: la riga per creare un nuovo secret non è più sempre visibile; compare con il pulsante «Aggiungi secret» e si chiude con «Annulla», per una schermata più pulita. Se salvi senza nome, la riga resta aperta segnalando l'errore invece di chiudersi senza avvisare.

## [0.8.1] - 2026-07-12

### Fixed

- **Campi a scelta azzerabili**: i menu a tendina facoltativi includono ora l'opzione vuota, così puoi rimuovere un gruppo da un progetto o svuotare gli altri campi opzionali quando non ti servono.

## [0.8.0] - 2026-07-12

### Added

- **Stato GitHub dei progetti**: nelle schede e nel dettaglio di ogni progetto vedi subito se è collegato a un repository GitHub. Vai ai [Progetti](/member/projects).

## [0.7.0] - 2026-07-12

### Added

- **Azioni sui server**: dall'app puoi ora installare gli aggiornamenti di sicurezza o riavviare un server in modo controllato, con conferma e senza bisogno di accedere manualmente alla macchina. ([guida](/member/guides/servers))

### Fixed

- **Autorizzazione da riga di comando più stabile**: premere due volte «Autorizza» mostra comunque l'esito positivo, e il pulsante si disattiva subito per evitare doppi invii.

### Changed

- **Pagine dei file segreti rinnovate**: le pagine dei file segreti, condivisi e di progetto, hanno un aspetto coerente con il resto dell'app, con il caricamento su una pagina dedicata e indicazioni chiare quando non c'è ancora nulla.

## [0.6.2] - 2026-07-12

### Fixed

- **Elenco completo dei repository GitHub**: quando colleghi un progetto a GitHub vedi tutti i repository disponibili, non più solo i primi trenta.

## [0.6.1] - 2026-07-12

### Fixed

- **File segreti più affidabili**: risolto un problema che, in alcune configurazioni, poteva impedire l'uso dei file segreti.

## [0.6.0] - 2026-07-12

### Added

- **Collegamento GitHub da riga di comando**: ora puoi collegare un progetto al suo repository GitHub anche dagli strumenti a riga di comando, non solo dall'app.

## [0.5.1] - 2026-07-12

### Fixed

- **Caricamento file segreti corretto**: risolto un errore che poteva comparire al primo caricamento di un file segreto.

## [0.5.0] - 2026-07-12

### Added

- **Panoramica progetti e GitHub per l'automazione**: gli strumenti a riga di comando possono ottenere l'elenco dei progetti con il repository collegato e il ramo predefinito, utile per le automazioni.

### Fixed

- **Contatore notifiche**: il numero delle notifiche in alto resta leggibile anche quando è grande.

## [0.4.1] - 2026-07-12

### Fixed

- **File segreti disponibili in tutti gli ambienti**: completata la configurazione necessaria a usare i file segreti in prova e in produzione.

## [0.4.0] - 2026-07-11

### Added

- **File segreti**: conserva in modo sicuro i file sensibili di un progetto, come certificati e chiavi. Sono cifrati, tengono uno storico delle versioni, si possono archiviare o eliminare e puoi condividerli con i progetti giusti.

### Security

- **Protezione dei file segreti**: i file segreti restano isolati e cifrati e non vengono mai esposti insieme alle altre variabili né sincronizzati altrove.

## [0.3.1] - 2026-07-11

### Fixed

- **Raccolte multi-progetto**: riordinare le pagine di una raccolta ora è più rapido e affidabile.

## [0.3.0] - 2026-07-11

### Added

- **Raccolte multi-progetto**: una raccolta della base di conoscenza può collegare più progetti e gruppi, riunire pagine di progetti diversi e comparire nella panoramica di ciascun progetto coinvolto, sempre nel rispetto dei permessi di ognuno.
- **Secret condivisi a griglia**: la pagina dei secret condivisi si compila come quella dei secret di progetto: un campo per ogni ambiente, celle nascoste che sblocchi quando serve e salvataggio dell'intera riga. La conferma è ora raggruppata per riga. Apri i [Secret condivisi](/member/shared/secrets).
- **Menu presenze**: nella barra di navigazione trovi un nuovo menu con azioni rapide e uno stato di connessione più chiaro.

## [0.2.1] - 2026-07-11

### Fixed

- **Niente release duplicate**: le versioni non compaiono più due volte e ogni versione mostra correttamente i propri errori.

## [0.2.0] - 2026-07-11

### Added

- **Secret condivisi**: variabili riservate condivise a livello di organizzazione, con un valore distinto per ogni ambiente, storico delle versioni e condivisione controllata verso i singoli progetti. ([guida](/member/guides/secrets))
- **Gestione dei secret condivisi**: una nuova schermata di amministrazione per gestirli, con storico, ripristino, tracciamento delle modifiche e vista in sola lettura nei progetti che li ricevono.
- **Distribuzione automatica**: i secret condivisi si aggiungono a quelli del progetto e arrivano senza modifiche nei download e nella sincronizzazione con GitHub.

### Fixed

- **Ripristino dei secret condivisi**: ora è possibile ripristinare un valore precedente anche quando è già stato condiviso con dei progetti.

## [0.1.0] - 2026-07-11

### Added

- **Nuovo sito pubblico**: una home rinnovata che racconta il percorso dal segnale alla risoluzione, con le funzionalità raggruppate in Rileva, Comprendi e Risolvi, disponibile in italiano e inglese e adatta a ogni dispositivo.
- **Richiesta di accesso su invito**: un nuovo modulo pubblico per richiedere l'accesso indicando nome, email, team e come lavori.

### Fixed

- **Rifiniture dell'interfaccia**: suggerimenti e note con colori più chiari, più colori tra cui scegliere per i progetti, selettore della vista progetti allineato alla roadmap e spaziature del monitoraggio corrette.

## [0.0.163] - 2026-07-11

### Added

- **Allegati sui ticket in evidenza**: un'icona a graffetta segnala subito i ticket che hanno allegati, negli elenchi e nelle schede. Apri i [Ticket](/member/tickets).

## [0.0.162] - 2026-07-11

### Added

- **Scheda Ambienti nel progetto**: una nuova scheda nel dettaglio del progetto offre una panoramica degli ambienti con accesso rapido al controllo di disponibilità.
- **Strumenti di monitoraggio rilevati in automatico**: gli strumenti collegati a un progetto vengono riconosciuti da soli, con lo storico delle versioni utilizzate.

### Fixed

- **Dettaglio ticket più ordinato**: le informazioni secondarie del ticket sono raccolte nel pannello Dettagli a destra e il pulsante «Segui» non cambia più forma quando lo premi.
- **Log più stabili**: limitata la dimensione dei dati extra registrati con ogni log, per evitare voci troppo pesanti.

## [0.0.161] - 2026-07-11

### Added

- **Dai log all'errore in un clic**: da un errore puoi passare direttamente ai log collegati alla stessa richiesta, con l'indicazione di quanti sono.
- **Promemoria sulla conservazione dei log**: le schermate dei log ricordano per quanto tempo vengono conservati.

### Fixed

- **Log più veloci**: l'elenco dei log si aggiorna in modo più fluido e leggero anche con molti dati in arrivo.

## [0.0.160] - 2026-07-11

### Added

- **Filtro temporale sui log**: puoi limitare i log a un intervallo di date scegliendo inizio e fine; l'elenco si aggiorna da solo. ([guida](/member/guides/logs))

### Fixed

- **Avvisi anche dai log gravi**: i log di errore e critici generano un avviso come gli errori, con l'indicazione del livello minimo che lo attiva.
- **Log e occorrenze allineati**: i log della richiesta seguono l'occorrenza selezionata, con un segnale per le occorrenze ripetute e un ordinamento degli errori correlati sempre coerente.

## [0.0.159] - 2026-07-11

### Added

- **Grafico delle occorrenze cliccabile**: puoi cliccare su una barra del grafico per vedere le occorrenze di quel periodo.

### Fixed

- **Distinzione dei crash non gestiti**: ora puoi filtrare e ricevere avvisi specifici per i crash non gestiti, anche sullo storico.
- **Avvisi sulle metriche più puntuali**: gli avvisi scattano quando una metrica supera la soglia, senza ripetersi a ogni singolo valore.
- **Niente ticket duplicati dal monitoraggio**: trasformare un segnale in ticket non crea più doppioni se l'azione parte più volte insieme.

## [0.0.158] - 2026-07-10

### Added

- **Gestione in blocco**: puoi elaborare più errori e metriche insieme direttamente dall'elenco.

### Fixed

- **Raccolta dati più robusta**: l'acquisizione di errori e metriche è più stabile e leggera quando arrivano molti dati insieme.
- **Metriche più efficienti**: l'elaborazione delle metriche è stata ottimizzata per gestire meglio grandi volumi di dati.
- **Riapertura errori più precisa**: quando un errore si ripresenta viene riaperto correttamente e l'avviso indica la versione in cui è ricomparso.

## [0.0.157] - 2026-07-10

### Added

- **Rilevamento dei picchi di errori**: il sistema riconosce le impennate improvvise di errori non ancora risolti.
- **Pannello operativo per gli amministratori**: nuovi indicatori di stato nel pannello di amministrazione, con la segnalazione di quando si sta operando per conto di un altro utente.
- **Elenco progetti più comodo**: nella home puoi cercare, filtrare e ordinare i progetti.

### Security

- **Permessi dei token più rigorosi**: un token creato solo per inviare dati non può più leggere le informazioni di monitoraggio.
- **Dati personali rimossi dalle metriche**: eventuali informazioni personali vengono ripulite dai dati delle metriche prima di essere salvate.

### Fixed

- **Avvisi sulle metriche più accurati**: le soglie che attivano gli avvisi tengono conto del tipo di metrica.

## [0.0.156] - 2026-07-10

### Added

- **Dashboard orientata alle priorità**: indicatori cliccabili che portano al punto giusto, azione consigliata per i progetti che richiedono attenzione e ordinamento dei progetti in base all'urgenza.
- **Scorciatoie da tastiera ovunque**: le stesse scorciatoie funzionano in tutte le pagine, con un aiuto sempre aggiornato su quelle disponibili.

### Fixed

- **Dashboard più affidabile**: segnalazione dei progetti senza monitoraggio o silenziosi, conteggi del backlog più onesti e collegamenti allineati ai numeri mostrati.
- **Navigazione riorganizzata**: il menu laterale è raggruppato per aree tematiche e la finestra delle scorciatoie è centrata.

## [0.0.155] - 2026-07-10

### Added

- **Raccolte nella base di conoscenza**: le pagine possono essere raggruppate in raccolte con una vista a indice. ([guida](/member/guides/knowledge))
- **Assegnatario predefinito dei ticket**: se non indichi un assegnatario, il ticket viene assegnato automaticamente in base alle impostazioni di progetto, gruppo o organizzazione.

### Fixed

- **Dettaglio ticket più coerente**: intestazione uniforme tra bacheca ed elenco e informazioni presentate in modo più pulito sotto il titolo.
- **Dettagli di monitoraggio più leggibili**: le occorrenze di errori e metriche sono suddivise in pagine e le informazioni tecniche sono presentate meglio.
- **Dettaglio progetto rifinito**: schede «Ticket aperti» e «Query più lente» cliccabili, aggiunta rapida di un server, collegamento al repository GitHub e diverse rifiniture di leggibilità.
- **Grafici di statistiche e server**: le visite del sito e le metriche di sistema dei server sono mostrate con grafici più chiari.
- **Controlli di disponibilità più snelli**: la scheda di un controllo mostra i dieci tentativi più recenti.
- **Interfaccia più pulita**: titoli del menu laterale più leggibili, barre di scorrimento nascoste senza perdere lo scorrimento e filtri raccolti in un riquadro dedicato.
## [0.0.154] - 2026-07-09

### Fixed

- **Segreti condivisi**: risolto un errore che, in alcuni casi, impediva di salvare il primo valore protetto di un progetto.

## [0.0.153] - 2026-07-09

### Changed

- **Pagina dei segreti ridisegnata**: i valori protetti di un progetto sono ora organizzati in una tabella con una riga per nome e una colonna per ambiente; restano nascosti finché non li sblocchi, puoi modificare un'intera riga in una volta, copiarli con un clic e consultarne lo storico.

### Added

- **Agenti**: gli agenti automatici possono ora conoscere i repository collegati a un progetto.

## [0.0.152] - 2026-07-09

### Added

- **Attivazione delle funzioni per ambiente**: per ogni progetto puoi scegliere in quali ambienti abilitare il monitoraggio dei server, i controlli di disponibilità e i valori protetti; dove una funzione è disattivata, le relative voci non si possono più creare.
- **Account di servizio**: puoi creare account non umani, pensati per l'accesso automatico ai valori protetti da riga di comando, senza bisogno di un login manuale.

### Security

- **Notifiche esterne più protette**: la chiave segreta che firma le notifiche verso sistemi esterni è ora conservata in forma cifrata e non viene più mostrata dopo il salvataggio.
- **Connessioni esterne più sicure**: le chiamate verso indirizzi esterni (notifiche e controlli di disponibilità) sono state rese più resistenti ai tentativi di reindirizzamento malevolo.
- **Nuove protezioni nelle pagine**: introdotte nuove difese contro contenuti non autorizzati nelle pagine, per ora in fase di osservazione.
- **Sessioni più sicure**: i dati di sessione viaggiano ora solo su connessioni cifrate.

## [0.0.151] - 2026-07-09

### Added

- **Cassaforte dei segreti**: conserva in modo sicuro le variabili di configurazione di ogni progetto (come password e chiavi), separate per ambiente; i valori sono cifrati e puoi decidere chi può leggerli o modificarli, sostituendo gli strumenti esterni per la gestione dei segreti.
- **Sincronizzazione con GitHub**: puoi sincronizzare automaticamente i valori protetti di un progetto con gli ambienti GitHub corrispondenti, senza toccare i segreti gestiti manualmente.
- **Storico e ripristino dei segreti**: ogni modifica ai valori protetti viene registrata; puoi consultare le attività recenti, rivedere le versioni precedenti e ripristinarne una.

## [0.0.150] - 2026-07-09

### Added

- **Visitatori online in tempo reale**: nella dashboard delle statistiche il numero di visitatori attivi ora diminuisce da solo quando il traffico cala, senza bisogno di ricaricare la pagina.

## [0.0.149] - 2026-07-09

### Changed

- **Statistiche in tempo reale**: la dashboard delle statistiche del sito si aggiorna ora da sola a ogni nuova visita — intestazioni, grafico e tabelle — senza ricaricare la pagina.

### Removed

- **Vecchio aggiornamento periodico**: rimosso il precedente sistema che aggiornava la dashboard delle statistiche a intervalli fissi, ora sostituito da quello in tempo reale.

## [0.0.148] - 2026-07-08

### Added

- **Galleria dei replay di sessione**: sfoglia tutte le sessioni registrate degli utenti — non solo quelle con errori — e riguarda ognuna come un video, con filtri per progetto, ambiente e pagina d'ingresso.
- **Più dettagli sulle sessioni**: le sessioni registrate includono ora la pagina d'ingresso, l'ultima pagina, l'elenco delle pagine visitate e un identificativo anonimo dell'utente.

### Changed

- **Conservazione dei replay**: il periodo di conservazione delle sessioni registrate accetta ora solo valori validi, da 1 a 365 giorni.

## [0.0.147] - 2026-07-08

### Changed

- **Pulsanti più coerenti**: i pulsanti delle azioni nelle pagine hanno ora un aspetto uniforme in tutta l'applicazione.

## [0.0.146] - 2026-07-08

### Added

- **Colori di stato nella riga di comando**: lo strumento a riga di comando mostra ora un pallino colorato per stato e priorità dei ticket, anche quando i nomi sono personalizzati.

## [0.0.145] - 2026-07-08

### Added

- **Grafico delle occorrenze più leggibile**: nei dettagli di un gruppo di errori o di metriche, il grafico nel tempo mostra ora i valori di riferimento, gli orari sull'asse e un riquadro informativo al passaggio del mouse — apri i [Gruppi di errori](/member/monitoring/error).

## [0.0.144] - 2026-07-08

### Added

- **Filtri sulle bacheche**: le bacheche di ticket, roadmap e carichi di lavoro hanno ora una barra con ricerca e filtri sopra le colonne, con i conteggi che riflettono i filtri applicati — apri i [Ticket](/member/tickets).

### Changed

- **Intestazioni delle pagine**: le azioni sono state spostate sotto i contatori e rese più compatte, con contatori aggiunti anche a log, ambienti e piattaforme.

## [0.0.143] - 2026-07-08

### Added

- **Accessibilità migliorata in tutta l'app**: interfaccia più accessibile, con messa a fuoco visibile sui controlli, migliore supporto per gli screen reader, menu navigabili da tastiera e bacheche utilizzabili senza mouse.
- **Registrazione delle sessioni**: introdotta la raccolta, la conservazione e la riproduzione delle sessioni utente, collegate ai relativi errori.
- **Navigazione in basso su mobile**: nell'area riservata, su smartphone le azioni principali sono ora disponibili in una barra in basso, con il profilo nel menu laterale.
- **Token per le automazioni**: nuovo tipo di token dedicato alle automazioni a livello di organizzazione.

### Changed

- **Testo più leggibile**: aumentato il contrasto del testo in tutta l'applicazione per una lettura più agevole.
- **Accessibilità — miglioramenti vari**: stato degli indicatori non affidato al solo colore, testo alternativo sulle immagini, collegamenti per saltare al contenuto e completamento automatico nei moduli di accesso.

### Fixed

- **Integrazione GitHub**: risolto un errore che poteva impedire il collegamento con GitHub.
- **Correzioni di accessibilità**: sistemati alcuni comportamenti nei menu a selezione multipla e nelle bacheche.

## [0.0.142] - 2026-07-08

### Fixed

- **Integrazione GitHub**: risolto un errore che in alcuni casi impediva di completare il collegamento con GitHub.

## [0.0.141] - 2026-07-08

### Changed

- **Attivazione dell'integrazione GitHub**: completata la configurazione necessaria per rendere operativa l'integrazione con GitHub.

## [0.0.140] - 2026-07-08

### Changed

- **Preparazione dell'integrazione GitHub**: aggiornata la configurazione interna per consentire la sincronizzazione delle credenziali GitHub.

## [0.0.139] - 2026-07-08

### Added

- **Integrazione con GitHub**: collega un progetto a un repository GitHub da una nuova scheda dedicata, con installazione a livello di organizzazione.
- **Versione attiva per ambiente**: ogni ambiente mostra ora quale versione è effettivamente in produzione, allineata automaticamente tra rilasci e tag di GitHub, con un'etichetta "live" sulla pagina del progetto.
- **Aggiornamenti automatici da GitHub**: l'applicazione riceve ora automaticamente gli eventi da GitHub, come push, tag, rilasci e pull request.
- **Branch e pull request dai ticket**: da un ticket puoi creare un branch o aprire una pull request su GitHub, e branch e PR esistenti si collegano da soli al ticket riconoscendone il codice; una pull request unita può chiudere il ticket — apri i [Ticket](/member/tickets).

## [0.0.138] - 2026-07-07

### Added

- **Navigazione su mobile**: su smartphone il menu laterale diventa un pannello a scomparsa richiamabile dall'icona in alto, così la navigazione principale è sempre raggiungibile.

### Changed

- **Tabelle più usabili su mobile**: le tabelle con molte colonne scorrono ora lateralmente senza tagliare i menu delle righe.
- **Miglioramenti responsive vari**: sistemati diversi dettagli di visualizzazione su mobile, tra cui timeline, preferenze di notifica, schede e moduli.
- **Aree di tocco più grandi**: le azioni principali nelle righe sono più facili da toccare su mobile.
## [0.0.137] - 2026-07-07

### Changed

- **Passaggi del ticket più leggibili**: i passaggi che descrivono un ticket ora sono disposti in modo più ordinato e compatto, con l'etichetta accanto al testo.

## [0.0.136] - 2026-07-07

### Changed

- **Più scenari per ticket**: ora un ticket può descrivere più situazioni (caso normale, caso limite e caso di errore) invece di una sola, e questo vale per ogni tipo di ticket.

### Added

- **Condizioni di completamento**: aggiungi a ogni ticket una checklist di condizioni da soddisfare perché sia considerato concluso.
- **Analisi tecnica separata**: ogni ticket ha ora uno spazio dedicato alle note tecniche, distinto dalla descrizione in linguaggio semplice.
- **Testi dei ticket più chiari**: l'assistente AI scrive descrizione, scenari e condizioni in linguaggio semplice e sposta i dettagli tecnici nel campo dedicato.
- **Nuovi campi nel form del ticket**: puoi aggiungere più scenari, più condizioni di completamento e l'analisi tecnica direttamente nel form, per ogni tipo di ticket.

## [0.0.135] - 2026-07-07

### Added

- **Gestisci i ticket da Telegram**: dal bot puoi aprire un nuovo ticket (anche allegando una foto o un documento), scegliere il progetto attivo, elencare i progetti, vedere stato e priorità di un ticket, elencare i tuoi ticket aperti, commentare un ticket e chiedere aiuto; vedi solo i progetti e i ticket a cui hai accesso.
- **Agenti (automazioni pianificate)**: nuova area per creare agenti che eseguono attività a orari prestabiliti, gestibili anche dalla riga di comando. Apri gli [Agenti](/member/agents).

## [0.0.133] - 2026-07-07

### Changed

- **Notifiche Telegram più chiare**: le notifiche su Telegram ora hanno un'emoji per il tipo di evento, il titolo in grassetto, il testo in forma di citazione e un link cliccabile che porta direttamente al ticket (o alla risorsa collegata); anche il riepilogo periodico usa lo stesso stile.

## [0.0.132] - 2026-07-07

### Added

- **Tutto nella tua lingua**: email, notifiche (in app, via email e Telegram), riepiloghi e pagine ora rispettano la lingua che hai impostato, e ogni destinatario riceve le notifiche nella propria lingua; le pagine prima dell'accesso seguono la lingua del browser.

## [0.0.131] - 2026-07-07

### Added

- **Colonna "Specifiche" nella Knowledge base**: la pagina di una voce ora mostra a lato un riquadro con progetto, tipo, lunghezza e tempo di lettura stimato, e chi l'ha creata o aggiornata.
- **Scelta della lingua**: scegli la lingua dell'interfaccia (italiano o inglese) dalle tue preferenze.

## [0.0.130] - 2026-07-07

### Added

- **Storico versioni della Knowledge base**: ogni modifica a una pagina ne salva una versione; puoi sfogliare la cronologia, aprire le versioni precedenti in sola lettura e ripristinarne una. Apri le [pagine della Knowledge base](/member/knowledge/pages).

## [0.0.129] - 2026-07-07

### Added

- **Dataset AI (nuova area "AI")**: crea tabelle di esempi con colonne di partenza e colonne da prevedere (anche foto), avvia l'addestramento e ottieni previsioni automatiche sui nuovi dati. Apri i [Dataset](/member/datasets).

## [0.0.128] - 2026-07-07

### Changed

- **AI Buddy con anteprima prima di compilare**: nel form di un nuovo ticket, l'AI Buddy è ora un pulsante che apre una finestra; scrivi cosa ti serve, vedi un'anteprima della bozza e solo quando confermi i campi vengono compilati (e restano modificabili).
- **Logo aggiornato**: il logo mostrato nell'app ora coincide con l'icona del sito, per un aspetto più coerente.

## [0.0.127] - 2026-07-06

### Added

- **AI Buddy: crea il ticket da una descrizione libera**: descrivi a parole tue cosa ti serve e l'assistente compone l'intero ticket (titolo, tipo e descrizione); resta una bozza che puoi rivedere e salvare.

## [0.0.126] - 2026-07-06

### Fixed

- **Collegamento Telegram riparato**: il pulsante "Collega Telegram" ora funziona correttamente; prima il collegamento non andava a buon fine.

## [0.0.125] - 2026-07-06

### Fixed

- **Il bot Telegram risponde all'avvio**: aprendo il bot con "Avvia" ora ricevi un messaggio di benvenuto che ti guida al collegamento; prima sembrava non rispondere.

## [0.0.124] - 2026-07-06

### Changed

- **Impostazioni in tre schede**: le impostazioni personali sono ora raccolte in un'unica area con tre schede — Preferenze, Notifiche e Telegram. Vai alle [preferenze](/member/preferences).

## [0.0.123] - 2026-07-06

### Changed

- **Board Workload allineata graficamente**: le intestazioni delle colonne della board Workload ora hanno lo stesso stile di quelle dei Ticket (pallino colorato ed etichetta).

## [0.0.122] - 2026-07-06

### Changed

- **Icona informativa più piccola**: il pallino "i" dei suggerimenti è ora più piccolo e discreto.

## [0.0.121] - 2026-07-06

### Changed

- **Board Kanban come vista predefinita**: aprendo i Ticket (e il Workload) ora vedi una board a colonne per stato con le schede trascinabili; la vecchia tabella resta disponibile nella "Vista lista". Apri i [Ticket](/member/tickets).

### Added

- **Board Kanban del Workload**: anche le attività del Workload ora si gestiscono su una board a colonne per stato; trascina una scheda per cambiarne lo stato, mentre la tabella filtrabile resta nella vista lista. Apri le [attività del Workload](/member/workload/actions).
## [0.0.120] - 2026-07-06

### Security

- **Notifiche Telegram più sicure**: il collegamento con Telegram usa ora un metodo di verifica più sicuro, che non lascia tracce nei registri interni.

## [0.0.119] - 2026-07-06

### Fixed

- **Collegamento Telegram funzionante**: attivare il bot Telegram e collegare il proprio account ora funziona correttamente.

## [0.0.118] - 2026-07-06

### Added

- **Preferenze notifiche personali**: per ogni tipo di avviso puoi scegliere se riceverlo via email o Telegram e con quale frequenza (subito, ogni giorno, ogni settimana o mai).
- **Avvisi nell'app sempre attivi**: le notifiche mostrate dentro l'applicazione arrivano sempre.
- **Telegram personale**: collega il tuo account a Telegram per ricevere gli avvisi come messaggio privato, con guida di attivazione e possibilità di scollegarti quando vuoi.
- **Riepiloghi periodici**: ricevi un riassunto giornaliero o settimanale dei tuoi avvisi invece dei singoli messaggi.

### Changed

- **Niente più disattivazione degli avvisi nell'app**: non puoi più spegnere del tutto le notifiche mostrate nell'applicazione né silenziarle per singola sorgente.

### Removed

- **Vecchio bot Telegram di organizzazione rimosso**: sostituito dal collegamento Telegram personale di ciascun utente; restano gli altri canali di notifica (Slack, Discord, webhook).

## [0.0.117] - 2026-07-06

### Fixed

- **Pannello delle novità**: risolto un problema di visualizzazione delle ultime novità mostrate nell'app.

## [0.0.116] - 2026-07-06

### Fixed

- **Suggerimenti informativi**: sistemato il testo di un suggerimento, completando l'introduzione dei nuovi suggerimenti informativi.

## [0.0.115] - 2026-07-06

### Added

- **Suggerimenti informativi nelle pagine**: accanto al titolo delle pagine di elenco trovi ora un pallino "i" che spiega a cosa serve la pagina e cosa ci trovi.

## [0.0.114] - 2026-07-06

### Added

- **Carico di lavoro (Workload)**: una nuova bacheca per gestire le attività non tecniche del team (fiere, materiale grafico, meeting, chiamate), separate dai ticket di sviluppo; ogni attività può avere più partecipanti ed essere collegata a un ticket o trasformata in uno nuovo. Apri il [Workload](/member/workload/actions).

## [0.0.113] - 2026-07-06

### Fixed

- **Segnalazione doppioni più chiara**: quando crei un ticket e compare un possibile doppione, se manca la motivazione ora vedi subito un avviso chiaro invece di un pulsante che sembra non fare nulla.

## [0.0.112] - 2026-07-06

### Security

- **Falla di sicurezza sui gruppi corretta**: da riga di comando un accesso limitato poteva elencare tutti i gruppi dell'organizzazione; ora vede solo quelli a cui ha diritto.
- **Permessi da riga di comando allineati al web**: le operazioni di lettura da riga di comando (avvisi, ambienti, piattaforme, membri, organizzazione) rispettano ora gli stessi permessi dell'interfaccia web.

### Added

- **Riga di comando completa**: gli strumenti da riga di comando coprono ora le stesse funzioni dell'area web (avvisi, statistiche, idee, log, membri, uptime, progetti, ticket e altro).

### Fixed

- **Link pubblici alle statistiche corretti**: non è più possibile creare un link pubblico alle statistiche di un progetto che non le ha attive.

## [0.0.111] - 2026-07-06

### Added

- **Log di sistema dei server**: nella pagina di un server vedi ora i log di sistema recenti (errori critici) e lo stato dei servizi che non funzionano. Apri i [Server](/member/monitoring/servers).

### Fixed

- **Stato dei servizi stabile**: l'elenco dei servizi di un server non si svuota più a intermittenza e gli avvisi non si ripetono senza motivo.

## [0.0.110] - 2026-07-06

### Added

- **Suggerimenti a comparsa**: in vari punti dell'applicazione un pallino "i" apre una breve spiegazione al passaggio del mouse o da tastiera.

### Fixed

- **Tabelle senza scorrimento laterale della pagina**: le tabelle larghe scorrono ora nel proprio riquadro, senza spostare l'intera pagina.

## [0.0.109] - 2026-07-03

### Added

- **Uptime diviso in due schede**: la pagina uptime ha ora due schede separate, una per i monitor e una per gli incidenti, con filtro per stato.

## [0.0.108] - 2026-07-03

### Added

- **Strumenti di monitoraggio per progetto**: nella pagina di un progetto una nuova scheda mostra quali strumenti stanno inviando dati, la loro ultima versione e se sono attivi, silenti o mai installati.

## [0.0.107] - 2026-07-03

### Added

- **Storico uptime a lungo termine**: i dati di disponibilità vengono riassunti automaticamente per conservare uno storico fino a un anno e oltre senza rallentamenti; la vista annuale mostra ora il dettaglio giorno per giorno.

## [0.0.106] - 2026-07-03

### Added

- **Gruppi di monitor e pagina di stato pubblica**: puoi raggruppare i monitor di disponibilità (anche di progetti diversi) e pubblicare per ogni gruppo una pagina di stato pubblica, con disponibilità e storico incidenti e senza mostrare dati interni. Apri i [Gruppi uptime](/member/monitoring/groups).

## [0.0.105] - 2026-07-03

### Added

- **Statistiche del sito molto più complete**: le statistiche di visita ora includono eventi e obiettivi personalizzati, tipo di dispositivo, browser e sistema operativo, paese, sessioni, confronto tra periodi, canali di arrivo e tempo reale; puoi anche condividere una pagina pubblica di sola lettura.

### Changed

- **Frequenza di rimbalzo per sessione**: la percentuale di rimbalzo delle statistiche è ora calcolata per sessione, per un dato più coerente.
## [0.0.104] - 2026-07-03

### Added

- **Errori con progetto e ticket in vista**: nella lista degli [errori](/member/monitoring/error) trovi ora due colonne dedicate, il progetto di provenienza e, quando un errore è stato trasformato in ticket, il collegamento al ticket.

### Changed

- **Meno ripetizioni nella lista errori**: le informazioni ora presenti nelle nuove colonne non compaiono più anche nel resto della riga, così lo stesso dato non appare due volte.

## [0.0.103] - 2026-07-03

### Added

- **Modifica delle idee da riga di comando**: dallo strumento a riga di comando puoi aggiornare un'idea (titolo, problema, soluzione, destinatari) e aggiungere nuovi casi d'uso, come già facevi dall'app.

## [0.0.102] - 2026-07-03

### Added

- **Gestione completa di un disservizio**: da ogni disservizio rilevato puoi aprire una finestra dedicata per seguirne la cronologia, aggiungere o togliere aggiornamenti ed eliminarlo del tutto.

### Changed

- **Tabella dei disservizi più ordinata**: le righe della tabella dei disservizi hanno ora una spaziatura uniforme e più pulita.

## [0.0.101] - 2026-07-03

### Fixed

- **Separazione dei disservizi senza errori**: separare un gruppo di disservizi ora funziona sempre; prima l'operazione poteva riuscire ma restituire un errore, adesso non accade più.

### Added

- **Scelta di quale disservizio conserva la cronologia**: quando separi un gruppo puoi scegliere quale disservizio mantiene il racconto e la cronologia degli aggiornamenti.

## [0.0.100] - 2026-07-03

### Added

- **Percorso di navigazione nelle pagine**: ogni pagina mostra ora in alto il percorso completo, dalla Dashboard fino al punto in cui ti trovi, così sai sempre dove sei e torni indietro con un clic.

### Changed

- **Percorso di navigazione più in evidenza**: il percorso è stato spostato dalla barra in alto all'intestazione della pagina, vicino al titolo.

## [0.0.99] - 2026-07-03

### Changed

- **Idee più strutturate**: quando scrivi un'[idea](/member/ideas) separi ora il problema dalla soluzione, indichi a chi può essere utile e aggiungi casi d'uso concreti uno alla volta, invece di un unico testo libero.

## [0.0.98] - 2026-07-03

### Added

- **Disservizi raccontati con una cronologia a fasi**: puoi raggruppare più finestre di disservizio in un unico evento e raccontarne l'evoluzione per fasi (rilevato, investigazione, correzione, monitoraggio, rientrato), con testi già pronti da personalizzare; la pagina di stato pubblica mostra l'avviso e lo storico.

## [0.0.97] - 2026-07-03

### Changed

- **Nuova home con lo stato in un colpo d'occhio**: la schermata iniziale è stata ridisegnata con una riga di verdetto (verde tutto a posto, ambra problemi aperti, rosso servizi giù), i segnali raggruppati per affidabilità e prodotto, un pannello "Serve attenzione" che trasforma i numeri in cose da fare e una tabella dei progetti allineata.

### Fixed

- **Menu laterale senza barra di scorrimento visibile**: il menu di navigazione laterale non mostra più la barra di scorrimento, pur restando scorrevole.

## [0.0.96] - 2026-07-03

### Changed

- **Eliminazione del progetto spostata nelle Impostazioni**: la zona per eliminare un progetto è ora in fondo alla scheda Impostazioni, insieme alle altre opzioni, invece che nella panoramica.

### Fixed

- **Pulsanti del progetto sempre presenti**: i pulsanti Modifica, Nuova idea e Nuovo ticket non spariscono più quando cambi scheda nel dettaglio di un progetto.

## [0.0.95] - 2026-07-03

### Fixed

- **Apertura di ticket e pagine dai risultati**: cliccando una riga nella lista dei ticket o della knowledge base la pagina si apre di nuovo correttamente, invece di mostrare "Contenuto mancante".

## [0.0.94] - 2026-07-03

### Added

- **Data di inserimento e scadenza sui ticket**: la lista dei [ticket](/member/tickets) mostra ora la data di inserimento e una nuova data di scadenza, entrambe ordinabili; la scadenza si imposta dal form del ticket.

### Changed

- **Ricerca migliorata su ticket e knowledge base**: la ricerca ha ora un pulsante "Cerca" esplicito e i risultati si aggiornano al volo senza ricaricare la pagina, con un indicatore di caricamento.

## [0.0.92] - 2026-07-03

### Fixed

- **Vista a schede dei progetti completa**: la vista a schede dei [progetti](/member/projects) mostra ora tutti i progetti (prima si fermava a dieci) e i contatori in alto corrispondono al totale reale.

## [0.0.91] - 2026-07-03

### Added

- **Raccolta statistiche attivabile per progetto**: puoi decidere progetto per progetto se raccogliere le statistiche di visita del sito; è disattivata all'inizio. ([guida](/member/guides/analytics))

### Changed

- **Dashboard statistiche più mirata**: la dashboard delle statistiche e il relativo menu elencano ora solo i progetti con sito web e raccolta attiva.
- **Nessuna raccolta quando è disattivata**: se la raccolta statistiche non è attiva, il progetto non registra le visite.

## [0.0.90] - 2026-07-03

### Added

- **Knowledge base di progetto**: ogni progetto ha ora pagine in stile documento (note, decisioni, guide) con una ricerca intelligente che trova i contenuti per significato tra i progetti a cui hai accesso. ([guida](/member/guides/knowledge))
- **Avviso sui ticket simili alla creazione**: quando crei un ticket che somiglia ad altri aperti o chiusi di recente nello stesso progetto, vedi un confronto affiancato e puoi collegarli, procedere comunque indicando una motivazione oppure tornare al form.
- **Knowledge correlata su ticket ed errori**: nella pagina di un ticket o di un gruppo di errori compaiono le pagine della knowledge base più vicine per argomento.
- **Domande in linguaggio naturale alla knowledge base**: puoi porre una domanda a parole tue alle pagine della knowledge base e ottenere una risposta con le fonti citate.
- **Knowledge base da riga di comando**: puoi consultare e gestire le pagine della knowledge base anche dallo strumento a riga di comando.

## [0.0.89] - 2026-07-03

### Changed

- **Pagina del server che si aggiorna da sola**: la pagina di dettaglio di un [server](/member/monitoring/servers) monitorato si aggiorna ora per intero in tempo reale (grafici, valori, container e stato), senza bisogno di ricaricarla.

## [0.0.88] - 2026-07-03

### Added

- **Release distinte per ambiente**: la stessa versione rilasciata in staging e in produzione è ora tracciata come due release separate, con un'etichetta dell'ambiente ben visibile nel dettaglio del progetto.
## [0.0.87] - 2026-07-02

### Changed

- **Barra in alto riorganizzata**: gli elementi in alto a destra sono ora raggruppati per funzione — stato, azioni e profilo — e l'indicatore di connessione è un semplice pallino colorato, più facile da leggere.

## [0.0.86] - 2026-07-02

### Changed

- **Menu laterale riorganizzato**: la sezione di monitoraggio, prima molto affollata, è ora divisa in gruppi più chiari per ritrovare prima ciò che cerchi.

### Fixed

- **Menu laterale più pulito**: i titoli di sezione compaiono solo quando hai accesso ad almeno una voce del gruppo.

## [0.0.85] - 2026-07-02

### Added

- **Nuova idea dalla pagina del progetto**: dalla pagina di un progetto puoi aprire subito il modulo per proporre un'idea, con il progetto già selezionato, come avviene per i ticket.

## [0.0.84] - 2026-07-02

### Fixed

- **Accesso degli amministratori a tutte le organizzazioni**: gli amministratori possono ora spostarsi liberamente tra tutte le organizzazioni senza restare bloccati.

## [0.0.83] - 2026-07-02

### Added

- **Ordinamento delle tabelle**: puoi ordinare qualsiasi elenco cliccando sull'intestazione di una colonna; l'ordine scelto viene mantenuto anche con filtri e viste salvate.

### Fixed

- **Viste salvate su server e processi pianificati**: salvare una vista dalle pagine dei server e dei processi pianificati ora funziona correttamente.

## [0.0.82] - 2026-07-02

### Added

- **Documenti di progetto**: ogni progetto ha ora una sezione per allegare documenti — PDF, file Office, testi, immagini e archivi fino a 25 MB — con tag, ricerca e filtri per ritrovarli facilmente.

## [0.0.81] - 2026-07-02

### Added

- **Idee**: una bacheca per ogni progetto dove il team propone idee, le vota e le discute, con la possibilità di trasformarle in ticket. Apri le [Idee](/member/ideas).
- **Bozza automatica con l'AI**: quando trasformi un'idea in ticket, l'AI propone un titolo e una descrizione già pronti, che puoi sempre modificare prima di confermare.
- **Organizza e filtra le idee**: la pagina delle idee raccoglie tutte le proposte con contatori per stato, filtri per stato e progetto e ordinamento per numero di voti.
- **Idee da riga di comando**: puoi consultare, creare, votare e commentare le idee anche dal terminale.
- **Permessi sulle idee**: l'autore gestisce sempre la propria idea, mentre i ruoli abilitati possono modificarla, eliminarla o convertirla.

## [0.0.80] - 2026-07-02

### Added

- **Approva o rifiuta la revisione di un ticket**: su un ticket in fase di revisione puoi approvarlo, portandolo a completato, oppure rifiutarlo indicando un motivo, che viene aggiunto alla discussione e notificato al responsabile. Apri i [Ticket](/member/tickets).

## [0.0.79] - 2026-07-02

### Added

- **Statistiche del sito**: CloseYourIt raccoglie le visite dei tuoi siti web nel rispetto della privacy, senza cookie e senza conservare gli indirizzi IP. ([guida](/member/guides/analytics))
- **Pannello delle statistiche**: un cruscotto mostra visite, visitatori, dati in tempo reale, pagine più viste e provenienze del traffico.
- **Durata di conservazione delle statistiche**: puoi scegliere per quanto tempo conservare i dati delle visite, a livello di progetto o di organizzazione.

## [0.0.78] - 2026-07-02

### Added

- **Ticket completi da riga di comando**: dal terminale puoi vedere l'intero contenuto di un ticket, esattamente come nella pagina web.
- **Allegati dei commenti da riga di comando**: le immagini e i file incollati nei commenti sono ora visibili anche dal terminale.
- **Scaricamento degli allegati dei commenti**: puoi scaricare anche i file allegati ai commenti di un ticket.
- **Ticket richiamabile per codice**: dal terminale puoi aprire un ticket usando il suo codice leggibile oltre all'identificativo interno.

## [0.0.77] - 2026-07-02

### Added

- **Sistema operativo e aggiornamenti dei server**: la lista dei server mostra il sistema operativo e segnala quando ci sono aggiornamenti o un riavvio in attesa. Vai ai [Server](/member/monitoring/servers).

### Changed

- **Colori di avviso dei server**: le barre di CPU, memoria e disco sono ora verdi sotto il 50%, gialle tra il 50 e il 79% e rosse dall'80% in su.

## [0.0.76] - 2026-07-02

### Added

- **Server in tempo reale**: lo stato dei server e i relativi contatori si aggiornano automaticamente, senza ricaricare la pagina.
- **Processi pianificati in tempo reale**: la lista e il dettaglio dei processi pianificati si aggiornano automaticamente a ogni esecuzione.
- **Contatori delle prestazioni in tempo reale**: i numeri in cima alla sezione prestazioni si aggiornano a ogni nuova misurazione.

## [0.0.75] - 2026-07-02

### Added

- **Chat a due colonne**: la pagina Chat ha ora un layout in stile messaggistica, con le conversazioni a sinistra e i messaggi a destra; su mobile vedi prima l'elenco e poi il singolo thread.
- **Contatori nel titolo della Chat**: l'intestazione della Chat mostra il numero di conversazioni e di messaggi non letti.

## [0.0.74] - 2026-07-02

### Added

- **Canali di avviso da riga di comando**: puoi creare ed eliminare i canali di notifica (webhook o Telegram) dal terminale, con le stesse opzioni disponibili sul web.

## [0.0.73] - 2026-07-02

### Security

- **Protezione dai file compressi dannosi**: i dati compressi ricevuti dai server vengono ora controllati in sicurezza, per evitare che un file creato ad arte saturi la memoria.

## [0.0.72] - 2026-07-02

### Fixed

- **Invio dati dai server ripristinato**: i dati compressi inviati dai server ora vengono ricevuti correttamente; prima ogni invio falliva.

## [0.0.71] - 2026-07-02

### Added

- **Gestione dei server da riga di comando**: puoi gestire l'intera flotta di server dal terminale, dallo stato alla rinomina, dalla pausa ai token di accesso.

## [0.0.70] - 2026-07-02

### Added

- **Monitoraggio dei server**: tieni sotto controllo i tuoi server con CPU, memoria, disco, temperatura, container, servizi di sistema e stato dei dischi, con avvisi automatici quando qualcosa non va e uno storico consultabile. ([guida](/member/guides/servers))

## [0.0.69] - 2026-07-02

### Added

- **Più dettagli sugli errori**: la scheda di un errore mostra ora i parametri della richiesta e informazioni aggiuntive sull'occorrenza, come server, ambiente di esecuzione e versione.
- **Dispositivi e versioni negli errori**: la scheda di un errore mostra ora i sistemi operativi e le versioni dell'app più frequenti tra le occorrenze.

### Fixed

- **Soglie di durata negli avvisi ora rispettate**: gli avvisi sulle prestazioni scattano solo quando la durata supera davvero la soglia impostata; prima la soglia veniva ignorata.

## [0.0.68] - 2026-07-02

### Added

- **Riepilogo salute del progetto**: in cima alla pagina di un progetto una fascia di riquadri mostra a colpo d'occhio errori aperti, disponibilità, volume dei log, ticket aperti e le operazioni più lente, ciascuno collegato al dettaglio.

## [0.0.67] - 2026-07-02

### Added

- **Controllo dei processi pianificati**: una nuova sezione ti avvisa quando un processo pianificato (cron) smette di funzionare e non dà notizie nei tempi previsti; il monitoraggio si attiva da solo alla prima esecuzione.

## [0.0.66] - 2026-07-02

### Changed

- **Pagine più veloci**: ottimizzato il caricamento di diverse pagine riducendo le interrogazioni ridondanti al database.
## [0.0.65] - 2026-07-02

### Added
- **Monitoraggio dalle app nel browser**: le applicazioni web possono ora inviare in sicurezza i propri errori a CloseYourIt.
- **Tracciamento delle versioni**: ogni progetto tiene traccia delle versioni che pubblichi; la scheda di un errore mostra in quale versione è comparso per la prima volta e, se un errore risolto ricompare, ti dice in quale versione è tornato.

## [0.0.64] - 2026-07-02

### Added
- **Ricerca intelligente dei ticket**: cerchi i [Ticket](/member/tickets) per significato e non solo per parole esatte; se il servizio non è disponibile, la ricerca torna automaticamente a quella per titolo.
- **Suggerimento duplicati**: mentre scrivi il titolo di un nuovo ticket, ti mostra i ticket simili già aperti, senza mai bloccarti.
- **Chiedi ai ticket**: poni una domanda in linguaggio naturale e ricevi una risposta basata solo sui ticket che puoi vedere, con citazioni cliccabili.
- **Errori simili più precisi**: i suggerimenti di errori simili tengono conto del significato, così emergono anche i casi più rari.

### Changed
- **Filtri più puliti**: le tabelle non mostrano più tutti i filtri insieme; un pulsante Filtri elenca quelli disponibili e li applichi al volo, rimuovendoli con un clic.

## [0.0.63] - 2026-07-02

### Added
- **Avvisi anche fuori dall'app**: puoi far arrivare gli avvisi su canali esterni come Telegram o un tuo indirizzo web, oltre che dentro l'app e via email; se un canale non risponde, gli altri continuano a funzionare.

## [0.0.62] - 2026-07-02

### Added
- **Avviso di scadenza del certificato**: per i siti controllati in https puoi ricevere una notifica quando il certificato di sicurezza sta per scadere, tra i [monitor di disponibilità](/member/monitoring/groups).
- **Controllo del contenuto della pagina**: puoi indicare una parola che deve comparire nella pagina; se manca, il controllo segnala un problema anche quando la pagina risponde "tutto ok", utile per intercettare pagine di errore o manutenzione.
- **Gestione delle piattaforme da riga di comando**: ora puoi dichiarare le piattaforme di un progetto anche da riga di comando, non solo dall'app.

## [0.0.61] - 2026-07-02

### Changed
- **Assistente AI più reattivo**: le analisi automatiche (segnalazione rapida di un bug, analisi di errori e metriche, ricerca di errori simili) girano ora in background: il pulsante risponde subito e il risultato compare appena pronto, senza rallentare l'app per gli altri.

## [0.0.60] - 2026-07-02

### Fixed
- **Compatibilità con gli strumenti Sentry**: verificata la piena compatibilità con gli strumenti Sentry ufficiali, con alcune correzioni perché gli errori arrivino, vengano raggruppati e ripuliti dai dati personali in modo corretto.

### Changed
- **Chiarezza sul passaggio da Sentry**: la documentazione del sito spiega con onestà che l'integrazione compatibile con Sentry copre gli errori, ma non tutti gli altri tipi di dati.

## [0.0.59] - 2026-07-02

### Changed
- **Tabelle più compatte**: le liste mostrano ora 10 elementi per pagina invece di 25, con la navigazione tra le pagine che mantiene filtri e ricerca; aggiunta la paginazione anche dove mancava.
- **Letture da programma invariate**: chi legge i dati tramite integrazione o riga di comando continua a ricevere gli ultimi 25 elementi, a prescindere da quanti ne mostrano le tabelle.

## [0.0.58] - 2026-07-02

### Added
- **Nuovo sito pubblico multilingua**: closeyour.it accoglie i visitatori con un sito vetrina in italiano e inglese, con pagina principale, pagine sulle funzionalità e integrazioni; chi ha effettuato l'accesso continua a vedere la propria dashboard.
- **Ottimizzazione per i motori di ricerca**: le pagine del sito pubblico sono predisposte per essere trovate correttamente sui motori di ricerca e condivise sui social.

### Changed
- **Struttura del sito rivista**: la pagina di stato pubblica e le pagine del sito hanno ciascuna la propria intestazione e il proprio piè di pagina.

## [0.0.57] - 2026-07-02

### Security
- **Protezione dalle scansioni automatiche**: le richieste sospette dei bot verso file e percorsi sensibili vengono bloccate.

### Removed
- **Rimosso il tracciamento errori esterno**: CloseYourIt non invia più i propri errori a servizi terzi come Sentry; li conserva nei propri log.

## [0.0.56] - 2026-07-02

### Added
- **Chat tra membri**: una nuova sezione Chat per messaggi diretti tra chi condivide un progetto e per canali legati a progetti o team; puoi citare risorse come ticket, errori o metriche con anteprime, con aggiornamenti in tempo reale e notifiche, e silenziare una conversazione quando vuoi.

### Security
- **La revoca degli accessi vale anche in chat**: chi perde l'accesso a un progetto non vede più le risorse citate e gli ex membri non ricevono più notifiche.

## [0.0.55] - 2026-07-02

### Changed
- **Maggiore affidabilità**: ampliati i controlli automatici interni per rendere l'applicazione più solida; nessun cambiamento nell'uso quotidiano.

## [0.0.54] - 2026-07-01

### Added
- **Suggerimenti nella pagina Ruoli**: in fondo alla pagina dei ruoli compaiono dei suggerimenti, con il promemoria che modificare un ruolo si riflette subito su team e membri.

### Changed
- **Conteggi riepilogativi sotto i titoli**: diverse pagine mostrano ora dei contatori riepilogativi sotto il titolo al posto delle frasi descrittive.
- **Pagina Todos**: il titolo e la voce di menu della pagina sono ora "Todos" anche in italiano.

## [0.0.53] - 2026-07-01

### Added
- **Novità e versione del sistema**: il fondo del menu laterale mostra ora la versione attuale del sistema; un clic apre una finestra "Novità" con le ultime modifiche e un link allo [storico completo](/member/changelog).

## [0.0.52] - 2026-07-01

### Added
- **Revisore del ticket**: ogni ticket ha ora un revisore (all'inizio chi lo apre, poi riassegnabile al volo); quando il ticket entra in revisione, il revisore riceve una notifica dedicata, solo in quel passaggio e non a ogni cambio di stato.

## [0.0.51] - 2026-07-01

### Changed
- **Utenti online più riservato**: l'elenco degli utenti online mostra ora solo te, i titolari e le persone con cui condividi almeno un progetto, gruppo o team, invece di tutta l'organizzazione.

## [0.0.50] - 2026-07-01

### Changed
- **Nuovo modulo dei ticket a due colonne**: creare e modificare un ticket usa ora un layout a due colonne, con il contenuto a sinistra e i dettagli (progetto, piattaforme, stato, priorità, assegnatario, milestone) in una barra a destra.

## [0.0.49] - 2026-07-01

### Added
- **Viste salvate ovunque**: i set di filtri con nome, prima solo sui ticket, ora sono disponibili su nove elenchi filtrabili tramite un menu "Viste" nella barra degli strumenti: selezioni una vista per applicarne i filtri oppure ne salvi una nuova.

## [0.0.48] - 2026-07-01

### Added
- **Commenti e allegati dei ticket da riga di comando**: ora puoi leggere i commenti di un ticket e scaricarne gli allegati anche da riga di comando, purché tu possa già vedere il ticket.

## [0.0.47] - 2026-07-01

### Added
- **Anteprima dei permessi effettivi**: nelle pagine di un [membro](/member/members) o di un team, i titolari vedono cosa quella persona può davvero fare su ogni progetto; modificando ruoli e permessi, l'anteprima si aggiorna in tempo reale evidenziando cosa verrebbe aggiunto o tolto prima di salvare.

### Fixed
- **Etichette dei permessi leggibili**: le etichette dei permessi che prima mostravano un testo mancante ora compaiono correttamente in tutta l'app.
## [0.0.46] - 2026-07-01

### Added

- **Liste di attività personali**: crea le tue liste di cose da fare, private e divise per organizzazione. Ogni voce si spunta, si riordina e può essere collegata a un ticket, e una lista si può condividere in sola lettura con i colleghi. Apri le tue [liste di attività](/member/lists).

## [0.0.45] - 2026-07-01

### Changed

- **Grafico delle metriche più chiaro**: nel dettaglio di una metrica le barre hanno ora un'altezza proporzionale al numero di occorrenze e un colore legato alla durata media, così vedi a colpo d'occhio volume e tempi di risposta insieme.

## [0.0.44] - 2026-07-01

### Added

- **Riepilogo nella home**: la pagina iniziale mostra ora un riepilogo dell'organizzazione (ticket aperti, errori non risolti, monitor non raggiungibili, log del giorno) e una riga per ogni progetto con il suo stato e le novità di oggi. Ognuno vede solo i progetti a cui ha accesso.

### Changed

- **Home più pulita**: rimosse le card segnaposto di team e organizzazione, sostituite dal nuovo riepilogo.

## [0.0.43] - 2026-07-01

### Fixed

- **Segnalazioni bug più semplici**: ora puoi salvare una segnalazione anche scrivendola in linguaggio naturale, senza compilare i campi strutturati. Bastano un titolo e una descrizione.

### Changed

- **Assistente AI che aiuta, non blocca**: mentre scrivi una segnalazione l'assistente propone domande e suggerimenti per migliorarla, ma non ti impedisce mai di salvare.

## [0.0.42] - 2026-07-01

### Added

- **Pagina di stato pubblica**: puoi pubblicare una pagina che mostra lo stato di un servizio (attivo, non raggiungibile, in pausa), l'affidabilità nel tempo e lo storico degli episodi, senza esporre alcun dato interno. Si attiva e si disattiva quando vuoi dalla pagina di un [monitor](/member/monitoring/monitors).

### Security

- **Pagina di stato protetta**: finché non la pubblichi la pagina non esiste; indirizzi errati o di altre organizzazioni non rivelano nulla, e lo stato mostrato è sempre aggiornato.

## [0.0.41] - 2026-07-01

### Added

- **Modifica dei dati di un membro**: chi ne ha il permesso può cambiare nome, email e handle di un membro da una pagina dedicata. Email e handle valgono in tutte le organizzazioni della persona. Vai ai [membri](/member/members).

### Security

- **Protezione dei membri più delicati**: chi non è titolare non può modificare i dati del titolare dell'organizzazione o di un account con pieni poteri, così un cambio di email o handle non può portare a un furto dell'account.

## [0.0.40] - 2026-07-01

### Fixed

- **Meno notifiche inutili sui ticket**: aprire un ticket non avvisa più tutto il team; la notifica arriva solo all'assegnatario, se diverso da chi lo ha aperto. Gli avvisi di monitoraggio continuano a raggiungere tutti. Apri i [ticket](/member/tickets).

## [0.0.39] - 2026-06-30

### Added

- **Analisi AI su richiesta per errori e performance**: dalla pagina di un errore o di una metrica puoi chiedere all'assistente un primo esame (categoria, gravità, causa probabile, azione consigliata) e trovare gli errori con la stessa causa. L'assistente propone, tu applichi con un clic. Vai agli [errori](/member/monitoring/error).

## [0.0.38] - 2026-06-30

### Added

- **Interruttori con salvataggio immediato**: nelle impostazioni di progetto puoi attivare o disattivare funzionalità come Roadmap e segnalazione rapida dei bug con un interruttore che si salva subito, senza ricaricare la pagina.
- **Piattaforma già selezionata**: aprendo un nuovo ticket su un progetto con un'unica piattaforma, questa risulta già scelta per te.

## [0.0.37] - 2026-06-30

### Fixed

- **Assistente AI del bug report corretto**: l'assistente ora compila davvero i campi della segnalazione a partire dal testo che scrivi.

## [0.0.36] - 2026-06-30

### Fixed

- **Assistente AI più affidabile**: risolto l'errore che a volte impediva l'analisi della segnalazione; ora, se il servizio non è disponibile, il modulo resta comunque compilabile a mano.

## [0.0.35] - 2026-06-30

### Added

- **Segnalazione bug rapida con assistente AI**: attivabile per progetto, permette di descrivere un problema con un testo libero; l'assistente lo trasforma in una segnalazione ben strutturata oppure ti fa qualche domanda per chiarire.

## [0.0.34] - 2026-06-30

### Added

- **Aggiornamenti in tempo reale**: errori, log, metriche, monitoraggio e ticket si aggiornano da soli senza ricaricare la pagina. Vedi anche chi è online e chi sta guardando la stessa risorsa.

## [0.0.33] - 2026-06-30

### Fixed

- **Miglioramenti interni di qualità**: rifiniture tecniche senza effetti visibili sull'uso quotidiano.

## [0.0.32] - 2026-06-29

### Added

- **Blocco delle scansioni automatiche**: i tentativi automatici di sondare l'applicazione, tipici di chi cerca falle, vengono bloccati subito e in silenzio, senza sporcare i log.

## [0.0.31] - 2026-06-29

### Added

- **Cronologia delle modifiche**: ogni ticket e progetto mostra chi lo ha creato e aggiornato e quando, con la cronologia completa consultabile in una finestra dedicata.

### Changed

- **Pannello dettagli del ticket ridisegnato**: le informazioni sono ora organizzate in sezioni (Persone, Classificazione, Contesto, Cronologia); la classificazione è in sola lettura mentre l'assegnatario resta modificabile al volo.
- **Pagina progetto più pulita**: rimosso il campo colore dal riquadro informazioni, che resta come pallino identificativo, e aggiunta la cronologia di creazione e modifica.

## [0.0.30] - 2026-06-29

### Changed

- **Nuovo logo e icona**: logo e icona dell'app aggiornati con l'icona a terminale del marchio, coerente in tutta l'applicazione.

## [0.0.29] - 2026-06-29

### Changed

- **Stato del ticket più coerente**: dalla pagina di dettaglio lo stato non si cambia più direttamente; si modifica dalla schermata di modifica o trascinandolo nella board.

## [0.0.28] - 2026-06-29

### Added

- **Permessi di sola lettura più precisi**: le pagine di gestione a livello di organizzazione (membri, piattaforme, ambienti, gruppi di progetti) sono ora visibili solo a chi ne ha il permesso; chi già le gestisce continua a vederle.
- **Roadmap attivabile per progetto**: la roadmap si accende quando serve, per singolo progetto o gruppo; quando è spenta scompaiono la voce di menu, le milestone e l'apertura di ticket di tipo funzionalità o miglioria.

### Fixed

- **Visibilità dei gruppi corretta**: l'elenco e il contatore dei gruppi rispettano ora ciò che ogni membro può effettivamente vedere.
## [0.0.27] - 2026-06-29

### Added
- **Collaborazione sui ticket**: ora ricevi notifiche in app ed email sui ticket che ti interessano, puoi seguire o smettere di seguire un ticket, menzionare un collega con la @ nei commenti e salvare i filtri che usi più spesso; apri i [Ticket](/member/tickets).

## [0.0.26] - 2026-06-29

### Changed
- **Dettagli ticket più compatti**: i dettagli di un ticket sono ora disposti su due colonne, così vedi le informazioni principali in meno spazio e più a colpo d'occhio.

## [0.0.25] - 2026-06-29

### Changed
- **Una sola pagina per le performance**: le due voci "Performance" e "Problemi di performance" sono state unite in un'unica pagina, con filtri per tipo e collegamento diretto a log ed errori della stessa richiesta; apri il [Monitoraggio performance](/member/monitoring/performance).

### Added
- **Icona e colore per progetti e gruppi**: puoi assegnare a ogni progetto o gruppo un'icona e un colore, usati in modo coerente in elenchi, menu ed etichette; apri i [Progetti](/member/projects).

## [0.0.24] - 2026-06-29

### Fixed
- **Ambienti coerenti nei nuovi controlli di disponibilità**: creando un nuovo controllo di disponibilità, l'elenco degli ambienti mostra ora solo quelli del progetto scelto, e puoi selezionare solo i progetti che hai il permesso di gestire.

## [0.0.23] - 2026-06-29

### Added
- **Controllo di disponibilità solo dove ha senso**: il controllo di disponibilità è ora proposto soltanto per i progetti raggiungibili via web, così non lo configuri dove non funzionerebbe.

### Changed
- **Pagina dell'errore più accessibile**: la schermata di dettaglio di un errore mostra le informazioni in modo graduale, è usabile da tastiera ed è più chiara per chi ha un ruolo di sola lettura; apri gli [Errori](/member/monitoring/error).

## [0.0.22] - 2026-06-29

### Fixed
- **Aggiornamenti di nuovo disponibili**: un problema che bloccava la pubblicazione delle nuove versioni è stato risolto, e i miglioramenti rimasti in attesa (correzioni alla disponibilità e monitoraggio delle performance) sono ora attivi.

## [0.0.21] - 2026-06-29

### Added
- **Rilevamento dei problemi di performance**: il sistema individua automaticamente i rallentamenti più comuni, come richieste lente, troppe richieste ripetute al database, chiamate esterne lente e scatti nelle app mobili.
- **Avvisi sulle performance**: ricevi una notifica quando un progetto supera la soglia di lentezza che hai impostato.
- **Pagina dei problemi di performance**: un elenco filtrabile con grafici, collegamento a log ed errori della stessa richiesta e la possibilità di trasformare un problema in ticket; apri il [Monitoraggio performance](/member/monitoring/performance).

## [0.0.20] - 2026-06-29

### Fixed
- **Controlli di disponibilità davvero ogni minuto**: un controllo impostato ogni 60 secondi veniva a volte eseguito ogni 120; ora rispetta l'intervallo e la barra di stato non presenta più buchi.

### Changed
- **Raccolta di errori e log più affidabile**: spostando il servizio su un'infrastruttura dedicata, tutte le tue app riescono ora a inviare errori e log senza interruzioni.

## [0.0.19] - 2026-06-29

### Added
- **Log ed errori della stessa richiesta collegati**: partendo da un errore puoi ora risalire ai log della stessa richiesta, per capire più in fretta cosa è successo.

### Security
- **Dati sensibili nascosti negli errori**: eventuali informazioni sensibili presenti nei dettagli di un errore vengono ora oscurate sul server, mantenendo comunque leggibile il resto.

### Fixed
- **Errore chiaro quando un invio di log non è valido**: se un intero blocco di log inviati viene scartato per intero, ricevi ora un errore esplicito invece di un falso "andato a buon fine".

## [0.0.18] - 2026-06-29

### Added
- **Tutto da riga di comando**: ogni operazione disponibile nell'area web (progetti, gruppi, piattaforme, ticket, controlli di disponibilità, avvisi, persone, inviti e allegati) è ora eseguibile anche dallo strumento a riga di comando.

## [0.0.17] - 2026-06-29

### Added
- **Log delle applicazioni**: un nuovo tipo di dati accanto a errori e metriche, per raccogliere i log delle tue app da un unico posto ([guida](/member/guides/logs)).
- **Collega log a errori e ticket**: puoi collegare manualmente un log a un errore o a un ticket, per tenere insieme le informazioni correlate.
- **Conservazione dei log configurabile**: decidi per quanto tempo conservare i log, a livello globale, di organizzazione o di singolo progetto (di base 14 giorni).
- **Pagina dei log**: uno storico consultabile e filtrabile per livello, ambiente, progetto, periodo o testo, con collegamento automatico a errori e log della stessa richiesta; apri i [Log](/member/monitoring/logs).
- **Invio dei log dalle app Ruby**: l'integrazione per applicazioni Ruby può ora inviare anche i log, oltre agli errori.

## [0.0.16] - 2026-06-28

### Changed
- **Eliminazione progetto più sicura**: l'eliminazione di un progetto è ora in una "zona pericolosa" ben evidenziata, con un avviso chiaro che rimuove il progetto e tutti i suoi ticket in modo irreversibile; apri i [Progetti](/member/projects).

## [0.0.15] - 2026-06-28

### Added
- **Avvisi dal monitoraggio**: il monitoraggio non si limita più a registrare ma ti avvisa, in app ed email, quando succede qualcosa di importante — come un nuovo errore o un sito non raggiungibile — con preferenze personali e orari di silenzio.
- **Email più curate**: le email di servizio (reimpostazione password, inviti, avvisi) hanno ora una veste grafica coerente e più leggibile.
- **Allegati ai ticket**: puoi allegare file a un ticket trascinandoli, con caricamento automatico; apri i [Ticket](/member/tickets).

## [0.0.14] - 2026-06-28

### Changed
- **Collegamento delle app semplificato**: la pagina di configurazione e le guide mostrano ora come collegare le tue app all'integrazione ufficiale CloseYourIt, indicando i due valori necessari (un codice segreto e l'identificativo del progetto).

### Added
- **Ambienti del progetto da riga di comando**: puoi dichiarare gli ambienti di un progetto anche dallo strumento a riga di comando.

## [0.0.13] - 2026-06-28

### Added
- **Gestione di ruoli e persone da riga di comando**: dallo strumento a riga di comando puoi gestire ruoli, team, membri e inviti, ad esempio per creare account cliente che vedono solo il proprio gruppo e i propri ticket.

## [0.0.12] - 2026-06-28

### Added
- **Creazione di progetti e gruppi da riga di comando**: puoi creare nuovi progetti e gruppi anche dallo strumento a riga di comando.

## [0.0.11] - 2026-06-28

### Added
- **Nuovo strumento a riga di comando**: è disponibile uno strumento da terminale con accesso sicuro, per lavorare su CloseYourIt senza aprire il browser.
- **Pagina degli errori più ricca**: la schermata degli errori mostra ora un grafico delle occorrenze nel tempo, il dettaglio di ogni singola occorrenza e filtri sulla tabella; apri gli [Errori](/member/monitoring/error).
- **Più contesto sugli errori**: ogni errore raccoglie più informazioni utili alla diagnosi (richiesta, utente, etichette e passaggi precedenti), con i dati sensibili rimossi automaticamente.

### Changed
- **Permessi più granulari (cambiamento importante)**: i permessi sono ora definiti per singola azione, con ruoli e team personalizzabili; il ruolo "admin" non ha più accesso totale e solo il proprietario vede e può fare tutto; gestisci tutto dalle [Persone](/member/members).
- **Moduli ridisegnati**: i moduli di inserimento usano ora un layout a tutta larghezza su due colonne, più ordinato e leggibile.
## [0.0.10] - 2026-06-27

### Added

- **Voti sui ticket**: chiunque veda un ticket può ora esprimere un voto a favore con un semplice tocco; sulla roadmap ogni proposta mostra quanti voti ha ricevuto e puoi ordinare le idee dalle più votate alle più recenti.

## [0.0.9] - 2026-06-27

### Added

- **Traguardi per progetto**: ogni progetto ha ora la sua roadmap con dei traguardi a cui collegare i ticket, scegliendoli dal modulo o trascinandoli, e una barra ti mostra a colpo d'occhio la percentuale di completamento di ciascun traguardo.

## [0.0.8] - 2026-06-27

### Added

- **Tipi di ticket e Roadmap**: ogni ticket ora è di un tipo — segnalazione, nuova funzionalità o miglioramento; le segnalazioni chiedono i dettagli passo dopo passo, mentre per funzionalità e miglioramenti bastano un titolo e una descrizione, e li ritrovi raccolti per stato nella nuova vista Roadmap dei [Ticket](/member/tickets).
- **Monitoraggio delle prestazioni**: CloseYourIt inizia a registrare i tempi delle operazioni, per far emergere quelle più lente della tua applicazione.

## [0.0.7] - 2026-06-27

### Changed

- **Cronologia uptime più chiara**: la striscia di disponibilità mostra ora blocchi di tempo regolari sul periodo scelto invece di pochi controlli allargati: verde se andava tutto bene, ambra se a tratti, rosso se era irraggiungibile, grigio se non ci sono dati. Pagina [Uptime](/member/monitoring/groups).

## [0.0.6] - 2026-06-27

### Fixed

- **Creazione dei monitor di uptime**: la creazione di un controllo di disponibilità falliva ogni volta perché mancava un nome; ora il nome viene assegnato in automatico e il salvataggio va a buon fine.

## [0.0.5] - 2026-06-27

### Fixed

- **Errori visibili sui monitor di uptime**: quando la creazione di un controllo di disponibilità non va a buon fine — ad esempio ne esiste già uno per quel progetto e ambiente — ora compare un messaggio chiaro invece di un fallimento silenzioso.

## [0.0.4] - 2026-06-27

### Added

- **Monitoraggio della disponibilità (uptime)**: CloseYourIt controlla a intervalli regolari che i tuoi progetti siano raggiungibili e mostra la percentuale di tempo online, i disservizi e i tempi di risposta su diversi periodi. I controlli si mettono in pausa e si riprendono. Pagina [Uptime](/member/monitoring/groups).

## [0.0.3] - 2026-06-26

### Added

- **Chiavi di connessione e ambienti dei progetti**: ogni progetto ha ora le proprie chiavi per inviare dati a CloseYourIt, distinte per ambiente (produzione, staging, sviluppo); le chiavi si mostrano una sola volta e puoi revocarle o rigenerarle quando vuoi.
- **Monitoraggio degli errori**: le tue applicazioni inviano in automatico gli errori a CloseYourIt, che li raggruppa e te ne mostra i dettagli; da lì puoi segnarli come risolti, ignorarli o trasformarli in un ticket, nella pagina [Errori](/member/monitoring/error).

## [0.0.2] - 2026-06-26

### Added

- **Sito ufficiale ed email reali**: CloseYourIt è ora raggiungibile sul suo indirizzo definitivo e invia email di notifica reali.

## [0.0.1] - 2026-06-26

### Added

- **Progetti e ticket**: crea i tuoi progetti e apri ticket compilati come una segnalazione guidata (cosa è successo e cosa ti aspettavi), con filtri e ricerca; organizzali su una bacheca in stile Kanban trascinandoli tra le colonne di stato e invita anche i clienti ad aprire i propri [Ticket](/member/tickets).
- **Gruppi di progetti e accessi per persona**: puoi raccogliere più progetti in un gruppo e decidere a chi darne accesso, gruppo per gruppo o progetto per progetto; da ora ogni membro vede soltanto i [Progetti](/member/projects) che gli assegni.
