# Ui:: — Catalogo componenti (CloseYourIt)

Libreria componenti del design system. Fonte di verità del design: `closeyourit-docs/DESIGN.md`
(sezione 8: le regole dell'interfaccia con il loro codice, A1…W1).
Catalogo interattivo: **Lookbook** su `http://localhost:3011/lookbook` (solo development).

## Approccio e convenzioni

- **Namespace `Ui::`**, file in `app/components/ui/`, classe `Ui::XComponent` + template `.html.erb`.
- **Tailwind nativo inline** (knowledge base `global/styling.md`): nessun CSS custom, nessun colore custom — solo
  palette Tailwind. Superfici flat, bordo 1px, **mai shadow**.
- **Varianti = simboli validati** contro mappe `frozen` nel componente; variante sconosciuta →
  `ArgumentError`. Niente conditional di stile in ERB.
- **Merge non distruttivo** di `class`/`data`/options del caller via `Ui::BaseComponent#merge_options`.
- **`test_id:`** → `data-test="..."` per i selettori E2E (knowledge base `global/design-system.md`).
- **Campi obbligatori**: marker `*` rosso accanto al label (`required: true`); mai `(opzionale)`.
- **i18n**: il testo visibile passa da `t(...)` lato view; i componenti non hardcodano copy.
- Ogni componente ha una **preview Lookbook** in `spec/components/previews/ui/` e una **spec** in
  `spec/components/ui/`.
- **Tema scuro (A32)**: i componenti e le pagine member (viste, helper, controller Stimulus, elencati
  in `spec/support/ui_dark_palette.rb`) hanno classi `dark:`; ogni colore chiaro ha il suo scuro sulla
  stessa riga, dalla mappa dello stesso file (`spec/config/dark_theme_spec.rb` lo verifica). In JS
  `classList` vuole una classe per argomento: lo scuro va come argomento a parte o sulla riga dopo. Si accende
  solo con la classe `dark` su `<html>`: dalla scelta del tema in Preferenze (chiaro, scuro, sistema)
  e dall'interruttore "theme" di Lookbook. Un componente
  nuovo va aggiunto all'elenco.

## Componenti

### `Ui::AssistantComponent`
Widget dell'assistente con pannello caricato alla prima apertura. Il trigger è **inline da 44px nella
topbar mobile** e diventa il FAB flottante da `md` in su, così non copre la bottom navigation.
`render Ui::AssistantComponent.new`
- Il pannello è unico e full-screen su mobile; `aria-expanded` resta sul trigger.
- Il layout lo rende nella topbar e non nelle pagine della conversazione, che hanno già il proprio frame.

### `Ui::ButtonComponent`
Bottone reso come `<a>` (`href` senza `method`), `<button>` (nessun `href`), oppure **button_to** (`href` + `method:` → form POST/PUT/PATCH/DELETE con CSRF + `_method` gestiti da Rails). È così che le azioni **mutanti** dell'header (watch/delete/approve/github) usano il componente invece di scrivere `button_to` a mano.
`render Ui::ButtonComponent.new(label:, variant: :primary, size: :md, type:, href:, method:, confirm:, form_class:, icon:, icon_only: false, disabled:, test_id:) { |b| b.with_trailing { … } }`
- **variant**: `primary` · `secondary` · `secondary_muted` (grigio low-emphasis+bordo: edit/back/github, es. watch inattivo) · `ghost` · `tinted` (indigo soft senza bordo, es. compose AI) · `tinted_outline` (indigo soft **con bordo**, es. watch attivo: stesso shape bordato del `secondary_muted` inattivo, cambia solo il colore) · `danger` (rosso solido) · `danger_outline` (rosso su bianco+bordo: delete/reject) · `success` (emerald solido: approve) · `success_outline` (emerald su bianco+bordo).
- **`icon_only: true`**: bottone quadrato con la sola icona. `icon:` e `label:` diventano **obbligatori** (`ArgumentError` se mancano): la label non si vede ma è l'unica etichetta accessibile → `aria-label` + `title` (tooltip nativo). Slot `trailing` e content non vengono resi.
- **size**: `sm` (h-7) · `md` (h-[34px], default) · `lg` (h-10). Azioni nell'header di pagina (slot `actions` di `PageHeaderComponent`) → **sm** (l'icona segue la size: sm→11px).
- `href` + **`method:`** (`:post`/`:put`/`:patch`/`:delete`) → button_to; **`confirm:`** → `data-turbo-confirm`; **`form_class:`** → classe del `<form>` wrapper (es. `pointer-events-auto`).
- slot **`trailing`**: contenuto dopo la label (es. badge conteggio watcher accanto a "Watch").
- `icon`: nome Lucide (es. `"plus"`). Content/`label` = testo.
- `form: "<id>"` (via options) → attributo `form` sul `<button>`: submette un form esterno (pulsanti nell'header pagina, non nel footer).
- **`form_id:`** (+ `href` + `method`) → azione mutante **senza `<form>` proprio**: `<button type="submit" form="<id>" formaction="<href>">`, il verbo diverso da POST come `_method` nel submitter. **Da usare in TUTTE le azioni di riga di un elenco** insieme a `Ui::RowActionsFormComponent`: un button_to per azione per riga porta un token CSRF diverso ciascuno, quindi il peso cresce con le righe e non si comprime (CYRA-571).

### `Ui::RowActionsFormComponent`
Il **modulo unico** che le azioni di riga di una pagina condividono. Reso una volta (di norma sopra l'elenco); i bottoni lo puntano con `form_id:` e scelgono l'indirizzo con `formaction`.
`render Ui::RowActionsFormComponent.new(id: "row-actions", test_id:, hidden: true) { … }`
- Nessun `action` sul `<form>`: lo sceglie la riga. Per questo il token è quello **globale** (`form_authenticity_token` senza `form_options`) — un token per-form verrebbe rifiutato appena il submit punta altrove.
- Con un **blocco** prende dei campi e resta visibile: è il caso del dialog condiviso (`ui--shared-dialog`), dove il motivo obbligatorio sta in pagina una volta invece che una per riga.

### `Ui::ButtonGroupComponent`
Bottoni **attaccati** (coppia di decisione, segmented control). Il wrapper porta raggio + `overflow-hidden`; i figli rinunciano al proprio raggio (`grouped: true` iniettato dallo slot, non dal caller) e restano squadrati dentro.
`render Ui::ButtonGroupComponent.new(test_id:) { |g| g.with_button(**opzioni_di_ButtonComponent) }`
- Lo slot `buttons` accetta le **stesse opzioni** di `Ui::ButtonComponent`.
- **Nessun bordo né divisore di default**: figli pieni → attaccati e basta (approva/rifiuta della home); figli trasparenti → il caller passa `class: "border border-stone-200 bg-white divide-x divide-stone-200"` (segmented control).
- **GOTCHA button_to**: un figlio con `href` + `method:` viene avvolto da Rails in un `<form>` che diventerebbe lui l'item della flex → passa **`form_class: "contents"`**.
- Usato in: riga del feed home (approva ✓ / rifiuta ✕ icon-only).

### `Ui::EmptyStateComponent`
Lo stato **«non c'è ancora niente»** — l'unico momento in cui il prodotto può insegnare sé stesso. Da usare SEMPRE al posto del riquadro `border-dashed` scritto a mano: lo schema (titolo, corpo, esempio, azione) è obbligato dal componente, non dalla buona volontà di chi scrive.
`render Ui::EmptyStateComponent.new(title:, body:, example:, icon: "inbox", compact: false, framed: false, test_id:) { |empty| empty.with_action { … } }`
- **title**: cosa manca, in una riga. **body**: a cosa serve quello che manca («serve a…», mai «non c'è niente»).
- **example**: un caso concreto che rende la spiegazione afferrabile; `nil` SOLO quando insegnerebbe un'azione a chi non può farla (CYRA-692) — in quel caso il paragrafo non si rende.
- slot **`action`**: il pulsante per farlo adesso; senza permesso non si passa lo slot.
- `compact` per le celle strette (colonne board): stessa struttura, meno aria.
- `framed: true` quando lo stato vuoto sta da solo nella pagina: il riquadro tratteggiato lo disegna il componente, mai un `<div>` intorno. Dentro una card già esistente (un pannello, la cornice di una tabella) resta `false`.
- NON è il caso «la ricerca non ha trovato»: quello è `Ui::NoResultsComponent` (sotto), e confonderli fa dire «non esiste niente» a un elenco pieno.

### `Ui::EmptyNoteComponent`
La riga vuota **dentro un pannello o una sezione** (CYRA-910): «Ancora nessun commento», «Nessuna dipendenza». Una riga sola, sempre lo stesso stile; non insegna, perché la pagina intorno c'è già.
`render Ui::EmptyNoteComponent.new(text:, hint: nil, inset: false, test_id:)`
- `inset: true` quando il corpo del pannello non ha padding (liste `divide-y`): aggiunge quello di una riga.
- `hint:` una seconda riga più leggera, solo se dice cosa fare.
- Pagina intera vuota → `Ui::EmptyStateComponent`; filtro senza risultati → `Ui::NoResultsComponent`.

### `Ui::NoResultsComponent`
Il gemello per l'altro caso (CYRA-555): l'elenco **non è vuoto, è il filtro a non aver trovato**. Tre parti obbligate: il titolo cita ciò che è stato cercato (o «con questi filtri»), il corpo facoltativo dice quanti elementi esistono davvero, e l'**uscita** — azzera e torna all'elenco intero — c'è sempre.
`render Ui::NoResultsComponent.new(reset_href:, query: nil, body: nil, icon: "magnifying-glass", compact: false, reset_label:, reset_test_id:, test_id:) { |no| no.with_action { … } }`
- **reset_href** (obbligatorio): l'indirizzo dell'elenco senza filtri. `query:` → il titolo cita il termine cercato.
- `body:` → la frase che smentisce il «non esiste niente» (es. «Ci sono N idee in tutto»). Nelle colonne strette si omette.
- slot **`actions`** (ripetibile): vie d'uscita specifiche della pagina (es. «Chiedi ai ticket»).
- La barra dei filtri NON si nasconde mai insieme alle righe (CYRA-687): il ramo vuoto-filtrato rende questo componente sotto la toolbar.

### `Ui::InputComponent`
Campo input con label, marker required, errore/hint.
`render Ui::InputComponent.new(name:, label:, type: "text", value:, placeholder:, required: false, error:, hint:, wrapper_class: nil, test_id:)`

`type: "textarea"` renders escaped multiline content; `rows:` defaults to 3.
It preserves the input's label, validation, hint and focus styling.
- `required: true` → asterisco rosso. `error:` → bordo rosso + messaggio (precede `hint`).
- `wrapper_class:` → classe sul `<div>` wrapper esterno (es. `"md:col-span-2"` nei form a griglia 2 colonne).

### `Ui::IconComponent`
L'unico modo di disegnare un'icona (DESIGN.md A31): glifo Lucide vuoto in SVG inline.
`render Ui::IconComponent.new(name:, label: nil, test_id: nil, class: …, data: …)`
- `name`: nome Lucide (elenco: `docs/plans/2026-10-01-lucide-names.txt`). Un nome sconosciuto solleva `ArgumentError`.
- Misura e colore dalle classi: `text-[11px] text-gray-400` (l'SVG è largo `1em`, tratto `currentColor`).
  `w-[1.25em]` = larghezza fissa nelle colonne d'icone; `animate-spin` = attesa (`loader-circle`).
- Senza `label:` è decorazione (`aria-hidden`); con `label:` diventa `role="img"` con quel nome.
- Ogni argomento `icon:` degli altri componenti prende un nome Lucide e passa da qui.
- Nei test si cerca `svg[data-icon='nome']`, mai una classe. In JavaScript: `icon(name)` da `lib/icon`
  clona le icone di `shared/_icon_templates`.
- Mai Font Awesome, mai icone piene, mai `<svg>` scritti a mano (eccezione: marchio del prodotto).

### `Ui::CardComponent`
Superficie card con slot opzionali.
`render Ui::CardComponent.new(highlighted: false, test_id:) { ... }` + `with_header` / `with_footer`.
- `highlighted: true` → bordo `indigo-600`.

### I mattoni di impaginazione (CYRA-748)

Quattro mattoni per COME sta insieme una pagina, accanto a quelli che disegnano un singolo
elemento. Le classi Tailwind stanno in **mappe letterali e frozen**: lo scanner legge il sorgente e
non vede una classe composta per interpolazione — `"gap-#{n}"` uscirebbe dal foglio di stile e la
pagina si presenterebbe senza spazi. Un valore fuori mappa è un `ArgumentError`, come per le
varianti di ogni altro componente. Il tetto di 200 righe per pagina è presidiato da
`spec/config/view_length_spec.rb`.

#### `Ui::StackComponent`
La pila: `space-y-*` in verticale, `flex` + allineamento + `gap-*` in riga.
`render Ui::StackComponent.new(direction: :column | :row, gap:, align:, justify:, wrap:, tag:, test_id:) { ... }`
- **gap**: 0–6, 8 e i mezzi passi (0.5, 1.5, 2.5, 3.5). Mappa diversa per colonna e riga.
- **align**: `start | center | end | baseline | stretch`; **justify**: `start | center | end | between | around`.

#### `Ui::GridComponent`
La griglia: colonne che crescono coi breakpoint, nell'ordine in cui crescono (mai in quello degli
argomenti).
`render Ui::GridComponent.new(cols:, sm:, md:, lg:, xl:, gap:, gap_y:, gap_x:, tag:, test_id:) { ... }`
- **cols/sm/md/lg/xl**: 1–6 e 12. Le colonne larghe si dichiarano sul figlio (`class: "lg:col-span-2"`).

#### `Ui::SectionComponent`
La superficie flat con l'intestazione **titolata** — il pannello più ripetuto del prodotto. Non
sostituisce `Ui::CardComponent`, che ha un'intestazione libera: qui l'intestazione È un `<h2>`.
`render Ui::SectionComponent.new(title:, tone:, tag:, body_class:, heading_size:, header_layout:, header_padding:, header_class:, collapsible:, collapsed:, test_id:) { ... }`
+ `with_title` (titolo composto: icona + testo) / `with_subtitle` (la riga sotto il titolo) /
`with_actions` (i comandi a destra).
- **body_class**: default `px-4 py-4`; **`nil`** = corpo nudo, per tabelle ed elenchi divisi che
  arrivano al bordo.
- **heading_size**: `sm` 13px · `base` 14px (default) · `md` 15px · `lg` 16px.
- **header_layout** (solo con le azioni): `between` (default) · `tight` · `row`.
- **header_padding**: `normal` (`px-4 py-3`) · `compact` · `tight` · `wide` (`px-5 py-4`).
  Sta in mappa e non fra le classi del chiamante: due `py-*` nello stesso attributo si contendono la
  stessa proprietà, e vince quella scritta dopo nel foglio di stile.
- **tone**: `default` · `amber` (la sezione che segnala qualcosa da guardare, bordo dell'intestazione
  compreso).
- **collapsible** / **collapsed**: la sezione diventa un `<details>` nativo e l'intestazione il suo
  `<summary>`, con la freccia a destra; `collapsed: true` la fa partire chiusa. Nessuno script, e
  la scelta non viene ricordata. `Ui::DetailsComponent` passa le due opzioni così come sono.

#### `Ui::DescriptionListComponent`
Le coppie etichetta/valore dei riquadri «Dettagli».
`render Ui::DescriptionListComponent.new(columns: 2, gap_y: 3, gap_x: 4, test_id:) { |list| list.with_item(...) }`
- **item**: `label:`, `value:` (o un blocco per il valore composto), `span:` (1–4 o `:full`),
  `value_class:`, `hint:`/`hint_title:`/`hint_test_id:` (il tooltip accanto all'etichetta), `test_id:`.
- Una voce senza `span` e senza classi del chiamante esce come `<div>` nudo: un `class=""` sarebbe
  markup che nelle pagine non c'è.

#### `Ui::DetailsComponent`
Il riquadro «Dettagli» a destra della pagina di un oggetto (E1, E2, E23): una riga per dato, etichetta a
sinistra e valore a destra; sul telefono l'etichetta va sopra il valore.
`render Ui::DetailsComponent.new(title:, test_id:) { |d| d.with_row(...); d.with_footer { ... } }`
- **row**: `label:`, `value:` (o un blocco per il valore composto), `action:` (il link piccolo accanto
  all'etichetta, es. «Gestisci token»), `test_id:`.
- Una riga senza valore né blocco non esce, e un riquadro senza righe non esce (E7): niente «—».
- **footer**: la riga «creato · aggiornato» in fondo al riquadro (E22).
- Prima pagina: `member/projects/_about_panel`. Gli altri riquadri Dettagli usano ancora
  `DescriptionListComponent` o `member/tickets/_detail_row`.

### `Ui::CardGridComponent` e `Ui::EntityCardComponent`
Una pagina di card è **un solo riquadro** (T1, D19): la barra dei filtri in cima, i gruppi di card
divisi da una riga sottile, «Da configurare» in fondo (D11), «Mostra altri» nel piede (D23).
`render Ui::CardGridComponent.new(test_id:, setup_test_id:) { |grid| grid.with_toolbar { … }; grid.with_group(...) { cards }; grid.with_more(href:); grid.with_setup_item(...) }`
- **toolbar**: `Ui::TableToolbarComponent` con `framed: true`; il raggruppamento è una scelta di «Vista ▾» (`group_by:`, D20).
- **group**: `title:` (senza titolo = raggruppamento «Nessuno»), `href:`, `count_label:`, `muted:`, `test_id:`,
  `title_test_id:`; slot `mark` e `actions`. Le card devono essere figli `<a>` diretti: così le altre si
  schiariscono al passaggio (D21).
- **no_results**: `Ui::NoResultsComponent`, al posto dei gruppi, sotto la barra (G4).
- **more**: `href:` con `limit` + 12, filtri e ordinamento tenuti (D23). Con `count:` il pulsante dice quante card aggiunge («Mostra altri 5»).
- **setup_item**: `label:`, `href:`, `test_id:`; il blocco è il segno. Piccolo e tratteggiato (D11).

`render Ui::EntityCardComponent.new(href:, title:, key:, description:, open_label:, open_hint_test_id:, test_id:) { |card| … }`
- Slot `mark` (segno), `meta` (accanto al codice, es. stato GitHub), `badges` (`Ui::BadgeComponent dot: true`, D22),
  `footer` (contatori Mono) e `footer_end` (a destra, sostituito da `open_label` al passaggio; senza piede, `open_label` compare in fondo alla riga dei badge e la card non cresce).
- Una card sola, nessun'ombra; al passaggio bordo più scuro e nome indigo (D21, A2).
- Prima pagina: `member/projects/_cards` e `_card`.

### `Ui::KanbanComponent`
Una board è **un solo riquadro** (T1, K9): la barra di ricerca e filtri in cima, le colonne affiancate
sotto, che scorrono di lato dentro il riquadro. Trascinamento, tastiera e colonne ridotte stanno nel
controller Stimulus della pagina, nominato da `controller:`; ogni colonna è un suo target `column`.
`render Ui::KanbanComponent.new(controller:, test_id:) { |board| board.with_toolbar { … }; board.with_column(...) { cards } }`
- **toolbar**: `Ui::TableToolbarComponent` con `framed: true` (C50).
- **column**: `key:`, `label:`, `color:`, `total:`, `test_prefix:`, `list_id:`, `count_id:`, `has_cards:`; opzionali
  `found:` (solo con una ricerca attiva: il numero diventa «trovati / totale», K11), `collapsed:` (la scelta
  salvata), `auto_collapsed:` (stretta dalla ricerca, mai salvata, K12), `data:` (attributi per il controller).
  Slot `note` (sotto il nome), `empty` (corpo senza card, K14), `footer` («Mostra altre» con `Ui::ButtonComponent`).
- Segnaposto: `<test_prefix>-column-<key>`, `-count-<key>`, `-collapse-<key>`, `-expand-<key>`. Il totale porta
  `data-board-total`, il conteggio della barra stretta `data-board-collapsed-count`: il controller li sposta di ±1.
- Titoli delle card con le parole cercate evidenziate: `board_card_title(title, params[:q])` (K13).
- Prime pagine: `member/tickets/_board` e `member/workload/actions/_board`.

### `Ui::ModalComponent`
Il guscio di ogni finestra (F24), uguale al modale che ospita ogni «Nuovo»: fondo scuro con lo
sfondo sfocato, riquadro del titolo con le azioni a destra, contenuto nel suo riquadro.
`render Ui::ModalComponent.new(title:, subtitle: nil, size: :md, padded: true, form: nil, test_id:, **dialog_options) { |modal| modal.with_actions { … }; <contenuto> }`
- `size:` `:sm` (conferme), `:md` (default), `:lg` (tabelle larghe). Valore ignoto → `ArgumentError`.
- `padded: false` quando il contenuto sono righe che hanno già il loro margine (cronologie, elenchi).
- `form:` sono le opzioni di `form_with`: titolo e riquadro stanno nello stesso form, così «Salva»
  nel riquadro del titolo invia il form. Mai un piede con i pulsanti.
- Le opzioni in più vanno sul `<dialog>`: il cablaggio resta del chiamante (`id`, `data-ui--dialog-target`,
  `data-action`…). Il componente non apre e non chiude niente da solo.
- Senza contenuto non disegna il riquadro vuoto (es. una conferma senza testo).
- Il riquadro del titolo resta fermo e scorre solo il riquadro del contenuto: i pulsanti sono sempre a portata.
- Il riquadro porta `data-test="<test_id>-panel"`.
- Mai un `<dialog>` scritto a mano con barra del titolo e piede propri. Eccezioni: ricerca globale e
  aiuto tastiera (palette).
- Prime pagine: `Ui::ConfirmDialogComponent`, `member/shared/_activity_modal`.

### `Ui::ConfirmDialogComponent`
La conferma di un gesto che non si annulla (F3, F16, C77): un `<dialog>` nativo con titolo che nomina la
cosa, testo che dice cosa sparisce, «Annulla» e il pulsante rosso che manda il gesto.
`render Ui::ConfirmDialogComponent.new(title:, url:, confirm_label:, method: :delete, test_id:) { |dialog| dialog.with_body { … }; <trigger> }`
- Il contenuto del blocco contiene il **pulsante che apre** la finestra. Nel menu ⋯ si usa
  `dialog.menu_trigger(label:, icon:, test_id:)`, mai un `<button>` scritto a mano (F1). Il menu
  (`Ui::RowMenuComponent`) sta dentro il blocco e la finestra fuori dal menu, così un `<details>`
  chiuso non la nasconde.
- Un gesto che è un bottone visibile nella riga (Revoca, Ripristina…) resta al suo posto:
  `dialog.button_trigger(label:, icon: nil, variant: :danger_outline, test_id:)`.
- Più gesti nello stesso menu ⋯ (un Ripristina per versione): ogni dialogo prende `dialog_id:` e sta fuori
  dal menu; la voce è `Ui::ConfirmDialogComponent::RemoteTriggerComponent.new(dialog_id:, label:, test_id:)`.
- `params:` aggiunge campi che il server controlla (es. `confirmation_digest`).
- Il pulsante rosso porta `data-test="<test_id>-confirm"` e manda già `confirm=1` (CYRA-728).
- Mai `turbo_confirm` né una pagina di conferma a parte (F16).
- Prima pagina: `member/environments/index`.

### `Ui::BreadcrumbComponent`
Breadcrumb "Home / … / corrente" resa in cima all'header di pagina. Il crumb **Home**
(root) è SEMPRE anteposto; l'ultimo crumb è la pagina corrente (testo, senza link, `aria-current`);
i crumb intermedi con `href` sono link. Di norma NON si usa direttamente: si passa `breadcrumb:` a
`Ui::PageHeaderComponent`.
`render Ui::BreadcrumbComponent.new(crumbs: [{ label:, href: }, …], root_href:, root_label:, test_id:)`
- **crumbs**: array di `{ label:, href: }` (href opzionale; l'ultimo è sempre la corrente).
- **root_href/root_label**: override del crumb Home — member usa il default (`root_path`,
  `member.nav.home`); valhalla passa `root_href: valhalla_root_path`.
- `data-test`: `breadcrumb` (nav), `breadcrumb-crumb` (ogni voce), `breadcrumb-sep` (separatore).

### `Ui::PageHeaderComponent`
Intestazione di pagina/form, disegnata come **pannello** (DESIGN.md T2, CYRA-925; mockup
`docs/mockups/secrets-panels.html`): **riga del titolo** con h1 e sottotitolo di una riga a sinistra e
**azioni a destra** (bottoni size **sm**; su schermo stretto vanno sotto da sole; mai una footer action
bar a fondo pagina). Sul bordo basso del pannello una riga con le **linguette** e, all'estremità destra,
i **conteggi** come testo (anche senza linguette). Il percorso in cima compare solo quando porta da
qualche parte.
`render Ui::PageHeaderComponent.new(title:, subtitle:, title_tooltip:, breadcrumb:, counts_test_id:, tabs_test_id:, root_href:, root_label:, test_id:) { |h| h.with_mark { … }; h.with_badges { … }; h.with_actions { … }; h.with_meta { … }; h.with_tab(…); h.with_more_tab(…); h.with_counts { … } }`
- **breadcrumb**: array `[{ label:, href: }, …]` reso da `Ui::BreadcrumbComponent` in cima (Home
  auto-anteposto). Trail per tipo: index `[{label: Risorsa}]`; show `[{Risorsa, href: index}, {item}]`;
  new `[{Risorsa, href: index}, {t("member.breadcrumb.new")}]`; edit `[{Risorsa, href: index}, {item, href: show}, {t("member.breadcrumb.edit")}]`.
  Un trail vuoto **non viene reso**; quello con la sola pagina corrente (le index) si vede solo se aggiunge
  il livello dell'area (B22): non sulle voci fisse del menu né in un'area che si chiama come la pagina.
- **`subtitle`**: stringa i18n, una riga corta che dice cosa c'è nella pagina. `data-test`: `<test_id>-subtitle` (o `page-header-subtitle`).
- **`title_tooltip`**: pallino "i" accanto al titolo. Resta solo per Valhalla: le pagine member usano `subtitle:`.
- slot **`counts`**: conteggi (`Ui::StatLabelComponent`) a destra nella riga in basso; `counts_test_id:` → `data-test` del wrapper.
- **`with_tab(label:, href:, active:, icon:, test_id:)`**: linguetta nella riga in basso (`icon:` = nome Lucide, es. `"lock"`). **`with_more_tab(…)`** stessa firma: finisce nel menu "Altro", che prende il nome della linguetta attiva (B14). `tabs_test_id:` → `data-test` del contenitore. Un file `_tabs` riceve l'header: `render "…/tabs", header: h, active_tab:`.
- slot **`mark`** / **`badges`**: pagina di un oggetto (B11) — quadratino prima del titolo, sigla Mono e badge dopo.
- slot **`actions`**: pulsanti sulla riga del titolo, a destra (size **sm**, es. Cancel + Submit con `form: "<id>"`).
- slot **`meta`**: pill di metadati sotto il titolo, nel blocco del titolo (su telefono prima delle azioni, CYRA-819) — niente prosa.
- `data-test` interni dal `test_id` (`project` → `project-title-row`, `project-actions`, `project-tab-more`, `project-back`); senza `test_id` → `page-header-*`.
- **root_href/root_label**: per l'area valhalla passare `root_href: valhalla_root_path`.
- `back_href`/`back_label`: link "← back" quando `breadcrumb:` non è passato. Ancora usati da alcune pagine.
- **Header compatto (B25)**: solo nell'area member l'header resta in cima scorrendo e ha una freccia
  dopo le azioni (`<test_id>-collapse`). Compatto mostra titolo, azioni, linguette e conteggi; nasconde
  percorso, sottotitolo e `meta`. La freccia salva la scelta sull'account per tutte le pagine
  (`page_header_compact`); lo scroll compatta senza salvare. Controller Stimulus `ui--page-header`.
  `collapsible: false` toglie freccia e aggancio in cima: serve a un `<dialog>` che la pagina rende da sé
  (Nuovo Puck), dove come nel modale condiviso non c'è niente da compattare.

### `Ui::AlertComponent`
Alert / flash. Content = messaggio; `title:` = parte in grassetto.
`render Ui::AlertComponent.new(variant: :info, title:, dismissible: false, test_id:) { "messaggio" }`
- **variant**: `success` · `warning` · `danger` · `info`
- `dismissible: true` → bottone X + Stimulus `ui--alert` (slide+fade in all'ingresso, auto-dismiss 5s, X chiude subito).
- I **flash** li renderizza il partial `shared/_flash` come toast floating in basso a destra, stacked, fuori dal flusso (nessuno shift del contenuto).

### `Ui::FloatingNoticeComponent`
Un messaggio importante che non appartiene a nessun pannello: galleggia sul fondo del riquadro del
contenuto, in un pannello suo con un titolo che dice cos'è. **Mai testo sciolto fuori dai pannelli.**
`<% content_for :floating_notice do %><%= render Ui::FloatingNoticeComponent.new(key:, title:, lifted: false, test_id:) { "messaggio" } %><% end %>`
- `key:` deve rispettare uno dei `KEY_FORMATS`: chiuderlo la salva sull'account (`dismissed_notices`) e non torna più, su nessun dispositivo. Una chiave che cambia col contenuto (i passi di un progetto) lo fa tornare quando il contenuto è nuovo.
- `lifted: true` lo alza sopra una barra appiccicata in fondo alla pagina (es. il Salva delle impostazioni).
- Solo pagine member: altrove non si rende. Controller Stimulus `ui--floating-notice`.

### `Ui::MarkdownComponent`
Testo libero scritto in **markdown** → HTML reso (CYRA-261). Unico punto di rendering per tutto ciò che
riempiono persone, riga di comando e agenti: descrizione/scenari/condizioni e commenti del ticket, piano
e passi della lavorazione, idee, chat, Knowledge, avvisi e aggiornamenti dei disservizi.
`render Ui::MarkdownComponent.new(text:, inline: false, remote_images: false, page:, links:, test_id:, class:)`
- **blocco** (default): contenitore `prose` coi margini stretti alla densità dell'app, backtick del plugin
  typography spenti (`prose-code:before/after:content-none`), checklist senza doppio marcatore.
- **`inline: true`**: niente `<p>` attorno a un testo di un blocco solo, per ciò che vive **dentro** una riga
  già formattata (uno step di scenario accanto alla sua etichetta, una voce di DoD nel suo `<li>`). Fuori da
  `prose`: colore e corpo del testo restano quelli della riga che lo ospita. Se il testo ha davvero **più
  blocchi** il contenitore passa da `<span>` a `<div>` — un `<ul>` dentro uno `<span>` farebbe chiudere al
  parser il `<p>` che lo ospita.
- **`remote_images: false` di default** (al contrario di `render_markdown`): il testo lo scrive qualcun altro
  e lo legge chiunque apra la pagina, e un'immagine remota è una richiesta che parte dal browser di chi legge.
  Le pagine Knowledge, scritte da chi ha `knowledge.edit`, passano `true`.
- **`max-w`**: il componente porta `max-w-none`, ma la cede se il caller ne passa una sua (`max-w-[70ch]` in
  Knowledge e nell'analisi tecnica) — due `max-w-*` sullo stesso elemento non si sommano.
- **`page:`/`links:`**: solo Knowledge, per risolvere i wikilink `[[Titolo]]` prima della conversione.
- Il testo scritto **senza** markdown non cambia: gli a capo singoli restano a capo. Il rendering è
  `MarkdownHelper` (Commonmarker safe, `escape: true`: l'HTML grezzo esce come testo visibile, mai markup).

### `Ui::BadgeComponent`
Badge / chip / status. Reso come `<span>`. Pallino colorato opzionale che può "respirare".
`render Ui::BadgeComponent.new(label:, color: :gray, dot: false, pulse: false, icon:, size: :md, test_id:)`
- **color**: nome colore Tailwind nativo — `gray` (neutral) · `red` · `orange` · `amber` · `green` ·
  `emerald` · `teal` · `sky` · `indigo` · `violet`. È **dato utente** (status/priority org-custom):
  un colore fuori palette fa **fallback a `gray`** (niente `ArgumentError` — la pagina non crasha).
- **dot**: `true` → pallino del colore a sinistra. **pulse**: `true` → il pallino respira
  (`motion-safe:animate-pulse`, fermo sotto *prefers-reduced-motion*); implica `dot: true`.
- **icon**: nome Lucide (es. `"crown"`, `"arrow-up"`). **size**: `sm` · `md` (default).
- Helper `ticket_status_badge(status)` → badge di uno `Types::TicketStatus` con `pulse: status.animated`
  (gli stati "in lavorazione" pulsano, data-driven).
- **Badge status/priority (Fase D)**: usare `Ui::BadgeComponent.new(color: status.color, label: status.label)`
  — `priority.code == "high"` → `icon: "arrow-up"`.

### `Ui::StatLabelComponent`
Conteggio come **testo in linea, mai pill** (DESIGN.md T12): numero Mono colorato, poi la parola in
grigio (`12 da fare`); tra conteggi vicini un puntino. Un valore che non è un numero tiene l'etichetta
davanti (`Ultimo controllo: 2 ore fa`). Con `href` è un link sottolineato (filtro, B4).
`render Ui::StatLabelComponent.new(label:, value:, value_color: :neutral, test_id:)`
- **label**: testo già localizzato (passa `t("stats.tickets", count: n)` ecc.: i nomi contati hanno singolare e plurale, M5). Dopo un numero diventa minuscola la prima lettera (le sigle restano: `23 CPU`).
- **value**: il numero. Reso in `font-mono font-semibold`.
- **value_color**: colora il VALORE — `neutral` (default, zinc-900) · `amber` (open/pending) · `indigo`
  (in_progress) · `emerald` (resolved) · `orange` · `violet` · `sky` · `teal` · `rose` · `gray`. Classi
  letterali; un valore fuori mappa fa **fallback a neutral** (niente crash), come `BadgeComponent`.
- Chiavi label condivise in `config/locales/stats/{en,it}.yml` (`stats.projects/groups/tickets/open/…`).
- Nelle pagine si passano nello slot `counts` di `Ui::PageHeaderComponent` (`counts_test_id:` per il `data-test`), mai in un wrapper scritto a mano.

### `Ui::NavLinkComponent`

Una riga del menu laterale member (CYRA-903): voci fisse, voci semplici, nome di un gruppo, foglie e
link dell'account nel menu mobile.

`render Ui::NavLinkComponent.new(label:, path:, icon: nil, active: false, current: "page", size: :top, test_id:, icon_class: nil)`

- `size`: `:top` (voce con icona, 13px), `:leaf` (foglia rientrata, senza icona), `:flyout` (foglia nel
  pannello che si apre nel menu stretto, senza rientro), `:footer` (Guide, in fondo, 12px), `:account` (12px).
- Le voci non si scrivono nelle viste: si dichiarano negli helper `Member::Nav*ItemsHelper` e in
  `Navigation::Group` (skill `closeyourit-design-system`, `sidebar.md`).
- `current`: il valore di `aria-current` quando è accesa — `"true"` per il nome di un gruppo che contiene la pagina aperta.
- Il blocco è il contenuto in coda (contatore, segno dell'area corrente). Nel menu stretto le voci `:top`
  tengono l'etichetta solo per i lettori di schermo e portano `data-nav-label`, che il controller
  `ui--sidebar-compact` usa come `title`.

### `Ui::MetricTileComponent`
KPI / metric tile della dashboard (sezione "Signals"): label + icona in cima, **valore grande** in
`font-mono text-[28px]`, con caption/delta opzionali sotto. Wrapper **polimorfico** come `ButtonComponent`
(niente markup manuale duplicato nelle view — CYRA-33).
`render Ui::MetricTileComponent.new(label:, value:, icon:, value_color: :neutral, href:, aria_label:, tooltip:, caption:, delta:, delta_color: :neutral, value_test_id:, test_id:)`
- **href** presente → `<a>` **cliccabile** (block + hover bordo/bg + focus-ring `indigo-500/40` per la
  navigazione da tastiera): le metriche azionabili linkano alla loro index già filtrata; passare `aria_label:`.
  **href** assente → `<div>` **statico**; `tooltip:` → attributo `title` nativo (hint accessibile).
- **value_color** / **delta_color**: colora il valore/delta — `neutral` (default, zinc-900) · `red` · `amber` ·
  `orange` · `violet` · `indigo` · `sky` · `emerald` · `teal` · `rose` · `gray`. Classi letterali; un valore
  fuori mappa fa **fallback a neutral** (niente crash), come `Badge`/`StatLabel`.
- **caption** / **delta**: righe opzionali sotto il valore (flow verticale `mt-1`, renderizzate solo se
  presenti → **niente layout shift**, il valore non viene coperto né spostato). Il testo del valore resta
  isolato dal loro.
- **test_id** → `data-test` sul wrapper (link/div); **value_test_id** → `data-test` sul `<p>` del valore
  (i due sono distinti: es. `home-kpi-errors` sul link, `home-stat-errors` sul valore).

### `Ui::SelectComponent`
Select **searchable** (regola `rules/forms-select.md`). Progressive enhancement: rende un `<select>`
nativo che **mantiene il `name`** (single `x`, multiple `x[]`) → submette e si testa senza JS
(rack_test fa `select`). Con JS lo Stimulus **`ui--select`** lo nasconde e mostra trigger + dropdown
con ricerca, sincronizzando la selezione sul `<select>`.
`render Ui::SelectComponent.new(name:, options:, label:, selected:, multiple: false, required:, placeholder:, include_blank: false, error:, hint:, test_id:)`
- `options`: array di `[label, value]` (3° elemento opzionale = famiglia colore per il pallino).
- `prefix: { text:, icon: }` (CYRA-883): parola fissa e icona dentro lo stesso trigger, prima del valore
  (es. «Ordina · Più errori»). Dentro una barra filtri, un wrapper `data-filter-bar-autosubmit` lo applica
  alla chiusura del menu, come i filtri.
- **multiple** → filtri (param array). **single** → picker di form (valore scalare).
- `wrapper_class:` → classe sul `<div>` wrapper esterno (es. `"md:col-span-2"` nei form a griglia 2 colonne).

### `Ui::SwitchComponent`
Toggle **auto-save senza reload**. Renderizza una riga (icona opzionale + label + hint, esito e switch
pill a destra) cablata allo Stimulus **`ui--switch`**: il toggle è ottimistico e persiste via `fetch`
PATCH su `url` con `{ name => "1"/"0" }`. Su risposta non-2xx (o errore di rete) reverte lo stato visivo.
Senza JS il bottone è inerte → la persistenza si copre col request spec (rack_test non esegue Stimulus).
`render Ui::SwitchComponent.new(name:, url:, label:, checked: false, hint:, icon:, test_id:)`
- `name`: chiave inviata nel PATCH (es. `"roadmap_enabled"`). `url`: endpoint che fa `update` (risponde `head :no_content` in JSON).
- `checked`: stato iniziale (`true` = `bg-indigo-600`, knob a destra). `icon`: nome Lucide (opz.). `label`/`hint` arrivano già tradotti (`t(...)`).
- **Dice da sé che si salva da solo** (CYRA-563): accanto alla pill sta «si applica subito» (`ui.switch.*`,
  target `status`, `aria-live="polite"`), che dopo il PATCH diventa «salvato» — sparisce da sé — o «non
  salvato», che resta finché non si riprova. Serve dove la stessa schermata ha anche campi che aspettano
  un Salva: senza, le due regole sono indistinguibili a occhio.
- **Il controller sta sul `<div>` della riga, non sulla pill** (`pill` è un target): Stimulus cerca i
  target solo dentro il proprio elemento, e l'etichetta dell'esito è fratello del bottone. `test_id`,
  `role="switch"` e le opzioni HTML del caller restano sulla pill.

### `Ui::TableComponent`
Shell tabella DS: **possiede l'overflow** + `<table>`/`<thead>`/`<tbody>`. La card esterna + toolbar
restano nella view.
`render Ui::TableComponent.new(scrollable: true, body_id:, test_id:) { ... }` + `with_head`.
- Slot `head` = le celle `<th>` (il componente avvolge in `<thead class="bg-stone-50"><tr>`); il blocco
  = le `<tr>` (di norma una render collection).
- **Overflow**: `overflow-x-auto` è il **default** (CYRA-670) — su mobile la tabella scorre lateralmente
  invece di far sforare l'intera pagina. `scrollable: false` è l'opt-out esplicito, e serve solo a chi
  ospita in una cella un pannello `absolute` che deve uscire dal riquadro (in CSS un asse non-visible
  costringe l'altro ad `auto`, quindi il pannello verrebbe clippato).
- Se esistono davvero colonne fuori campo, `ui--scroll-hint` mostra anche la pill localizzata
  «Scorri per vedere altro»; sparisce una volta raggiunta la fine e non viene resa sulle tabelle strette.
- **Niente flag per il row-menu**: `Ui::RowMenuComponent` usa un pannello `position:fixed` (controller
  `ui--row-menu`) che sfugge all'overflow → NON viene clippato. Il vecchio `menu:` non esiste più e il
  componente **solleva `ArgumentError`** se lo riceve (altrimenti uscirebbe come attributo HTML).
- **I pezzi da accendere** (CYRA-924, DESIGN.md C48–C81), tutti dal componente, mai scritti nella pagina:
  - `label:` e `table_data:` vanno sul `<table>` (nome per i lettori di schermo, tastiera della C74).
  - `stacked: true`: sotto 768px ogni riga diventa una scheda **solo con lo stile** (C26, C73): la
    riga resta una, così un Turbo Stream ne sostituisce un pezzo solo.
  - `compact: true` (C53), `sticky: :first | :last | :both` (C59, C75), `grouped: true` (C57).
  - Slot `state` (C51): `t.with_state(kind: :empty | :no_results | :loading | :error, title:, body:,
    reset_href:, reset_label:)`, reso dentro il corpo, sotto le intestazioni, su tutte le colonne.
  - Slot `foot`: il `<tfoot>` per la riga dei totali.
  - `t.column_count`: quante colonne ha l'intestazione, per le righe che le attraversano tutte.
  - `HeaderComponent label_hidden: true`: la colonna stretta della › (o di una sola azione), etichetta
    solo per i lettori di schermo e niente spazi ai lati; mai un `<th>` scritto a mano (C49).
- **Righe e celle**: `Ui::TableComponent::RowComponent` (`href:` + `link_label:` = tutta la riga apre il
  dettaglio con la › in fondo, C55; `highlighted:` C70; `selected:` C74; `faded:` C79; `group:` +
  `hidden:` per i gruppi), `CellComponent` (`label:` = nome della colonna sulla scheda; `header:` = la
  cella del nome; `align:`, `mono:`, `actions:`; `visible: false` C76,
  come `HeaderComponent`; gli stati eccezionali sono pillole, mai una cella colorata, C67), `GroupRowComponent` (`key:`, `label:`, `count:`, `colspan:`, `collapsed:`, `href:`; slot `with_actions` → bottone o menu ⋯ del gruppo a destra).
  Il padding delle celle viene dalla densità della tabella: le celle non scrivono `px-*`/`py-*`.
  - Selezione multipla (C56): `selectable: true | { test_id: }` sulla tabella mette «seleziona tutti»
    davanti alle intestazioni; ogni riga porta la sua casella con `RowComponent select: { value:, name:,
    label:, test_id:, data: }` (`select: :none` = cella vuota per la riga non selezionabile). Collegate a
    `ui--bulk-select`, il form resta nella pagina.
  - Riga dentro un Turbo frame: `RowComponent frame: "_top"` apre il dettaglio a pagina piena.
  - Riga di dettaglio (C58): `DetailRowComponent.new(colspan: t.column_count, hidden:)`, una cella su
    tutte le colonne; il contenuto porta il proprio padding.
  Esempi nel catalogo: preview `matrix`, `rows`, `grouped`, `states`. Prima pagina migrata: i secret
  di progetto (`member/project_secrets`).
- ⚠️ **`<dialog>` modali**: aperto con `showModal()`, lo user-agent stylesheet applica al dialog
  `overflow: auto` (+ `max-height`) → clippa i dropdown `absolute` interni. Un `<dialog>` che contiene
  `Ui::SelectComponent` (o altri dropdown absolute) DEVE avere `overflow-visible` tra le classi (es.
  modale "New conversation" in `member/chat_conversations/index.html.erb`).
- `body_id:` → `id` sul `<tbody>` (target Turbo Stream, es. `valhalla_accounts`).

### `Ui::RowMenuComponent`
Kebab menu azioni di riga: `<details>` nativo (apre senza JS). Il pannello è riposizionato a
`position:fixed` dal controller Stimulus `ui--row-menu` → NON viene clippato dentro una
`Ui::TableComponent`, che ha `overflow-x-auto` di default. Senza JS resta `absolute` (fallback ok solo
sulle tabelle in opt-out `scrollable: false`).
`render Ui::RowMenuComponent.new(width: :md, test_id:) { ...voci... }`
- **width**: `md` (w-44, default) · `lg` (w-48).
- **icon**: icona Lucide del trigger (default `ellipsis`); serve quando due menu stanno affiancati.
- Voci = `link_to`/`button_to` con `class: Ui::RowMenuComponent.item_class(:default | :danger)`;
  separatore `<div class="my-1 border-t border-stone-200"></div>`.
- Il pannello è dentro un `<details>` collassato → nei system/spec usare `visible: :all` per i selettori
  delle voci.

### `Ui::UserMenuComponent`
Menu utente dell'header: `<details>` nativo (apre senza JS) con le **iniziali** come trigger (il nome è
l'`aria-label`) e un pannello che apre con **nome ed email** (CYRA-898), poi la voce **Preferenze**
(opzionale, `account_path`), l'ingresso **Valhalla** (opzionale, area god) + **Esci**. Riusa `Ui::RowMenuComponent.item_class`.
`render Ui::UserMenuComponent.new(name:, logout_path:, email: nil, account_path: nil, account_label: nil, valhalla_path: nil, valhalla_label: nil, valhalla_test_id: nil, logout_label: nil, trigger_test_id:, account_test_id:, logout_test_id:)`
- **name**: stringa già risolta (di norma `account_display_name`: nome se presente, altrimenti email).
- **account_path** assente → niente voce Account (es. header valhalla, o member senza organizzazione).
- **valhalla_path** presente (solo god) → voce corona separata da un divider dalle azioni quotidiane
  (CYRA-331: l'ingresso god non sta più tra le icone della topbar, ma qui con etichetta esplicita).
- **logout_label** assente → default `t("home.sign_out")`. L'Esci è un `button_to … method: :delete`.
- Nel layout member questo menu vive nell'header ed è mostrato **solo su `md+`** (`hidden md:flex`):
  su mobile il profilo è nel drawer laterale (voci Account/Esci in `member/layouts` aside).
- Voci dentro un `<details>` collassato → nei system/spec usare `visible: :all`.

### `Ui::PresenceMenuComponent`
Controllo realtime dell'header che unisce stato Action Cable e utenti online in un trigger largo quanto
il suo contenuto (CYRA-898). `render Ui::PresenceMenuComponent.new(accounts:, viewer: nil)`.
- Il trigger cambia forma col breakpoint: riga libera nella barra su mobile (pallino, conteggio verde,
  avatar), quadrato `34px` col solo pallino su `md`, larghezza sul contenuto da `lg`.
- **Il conteggio compare solo da `xl`** (`xl:block`): a 1024px l'header è pieno (regressione CYRA-634).
- Fino a quattro avatar; con più di quattro account mostra tre avatar e un quarto tondo `+N` con tutti i
  rimanenti. Niente slot vuoti riservati: il trigger cambia larghezza quando entra o esce qualcuno.
- **`viewer`**: se l'unico online è lui, al posto di avatar e conteggio compare «Solo tu»
  (`presence-only-you`). Broadcast e snapshot passano il destinatario.
- Il pannello `<details>` elenca tutti gli account visibili in `w-56`, con massimo sei righe prima dello
  scroll; senza account mostra lo stato vuoto localizzato.
- La root conserva l'id Turbo `presence_list`: snapshot e broadcast sostituiscono l'intero componente.
  Pallino e parola espongono i target `connection-status.icon` e `.text`: il controller riapplica lo
  stato dopo ogni sostituzione Turbo e mostra la parola solo quando la connessione non è a posto.
- Stati icona: link verde connesso, link ambra pulsante in riconnessione, link spezzato rosso offline;
  testo screen-reader e `aria-label` rendono lo stato indipendente dal colore.

### `Ui::TableToolbarComponent`
Barra sopra una tabella-lista: `form_with` **GET** con search (`name="q"`) + slot filtri
(`Ui::SelectComponent`) dentro il menu Filtri. Con JavaScript i filtri si applicano alla chiusura del menu; il bottone Apply resta solo come riserva senza JavaScript.
- **Sempre dentro il riquadro** (DESIGN.md C50, T5): `framed: true` su ogni lista, anche quando i
  risultati stanno in un Turbo frame. Il riquadro bianco contiene barra, intestazioni, righe e
  paginazione, e porta il `data-test` della lista.
- **Mai un conteggio** (`count:`) nella barra: i numeri stanno nella riga dei conteggi dell'header di
  pagina (C63, T12).
- Campo vuoto: mostra il tasto `/` che lo raggiunge; con una ricerca: una ✕ che la svuota tenendo gli altri filtri.
`render Ui::TableToolbarComponent.new(framed: true, url:, query:, search_placeholder:, apply_label:, search_test_id:, test_id:) { |t| t.with_filter { ... } }`
- Il form **non** porta `page` → ogni submit riparte da pagina 1.
- `search_placeholder` assente → niente search box. Senza filtri → niente bottone Apply.
- I filtri sono slot `with_filter` (di norma `<div class="w-40"><%= render Ui::SelectComponent... %></div>`).
- Menu **Vista ▾** a destra (C62, CYRA-924): `group_by: [{ label:, href:, active:, hint:, test_id: }]` → voci
  «Raggruppa per» con la spunta su quella attiva (mai pillole né bottoni); slot `with_views` → le viste salvate
  (`Ui::SavedViewsComponent`) sotto, fuori dal form GET. Slot `with_trailing` → widget a destra al posto del `count`.
  `view_sections: [{ heading:, data:, choices: }]` → altre sezioni sopra «Raggruppa per» (es. «Mostra come»,
  «Ordina» delle schede): ogni voce è un link (`href:`) o un bottone che invia un form di preferenza della pagina
  (`form:`); `data:` della voce e della sezione per i controller Stimulus.

### `Ui::SavedViewsComponent`
Widget "viste salvate" nel menu Vista di una tabella filtrabile (via slot `with_views`, C37): sezione
ricercabile (Stimulus `ui--saved-views`) con le viste dell'utente (click = applica via GET coi param
salvati, X = elimina) + voce "aggiungi altra" che apre un `<dialog>` (`ui--dialog`) col riepilogo dei filtri
correnti + campo nome + casella «Salva anche i filtri» (spuntata; vuota = solo raggruppamento e ordine,
`SavedView.view_keys`), per salvarli come nuova vista.
`render Ui::SavedViewsComponent.new(resource_type:, views:, index_helper:, current_filters:, test_id:)`
- `resource_type` = una delle risorse in `SavedView::FILTER_KEYS` (tickets, error_groups, log_entries,
  metric_groups, uptime, groups, members, platforms, environments).
- `index_helper` = symbol del path helper dell'index (es. `:member_tickets_path`) per i link di applicazione;
  `current_filters` = i `params` correnti (solo le chiavi ammesse finiscono negli hidden del form).
- Backend: `SavedViews::Save` + `Member::SavedViewsController` (create/destroy). i18n `shared.saved_views.*`.
- Il controller index carica `@saved_views` via `saved_views_for(resource_type)` (`Member::BaseController`).

### `Ui::PaginationComponent`
Footer di paginazione, costruito da un oggetto `Pagination::Result` (`app/services/pagination.rb`).
`render Ui::PaginationComponent.new(pagination:, test_id:)`
- Mostra sempre `from–to of total` (i18n `pagination.info`); con 1 sola pagina nessun controllo.
- prev/next + finestra numerata (±2) con ellissi e prima/ultima; gli URL preservano i filtri correnti
  (query string) cambiando solo `page`.
- Paginazione lato controller: `@pagination = Pagination.call(scope, page: params[:page])` →
  `@records = @pagination.records`; il totale va nella riga dei conteggi dell'header, non nella toolbar (C63).

**Tabella-lista completa** = una sola card `rounded-lg border border-stone-200 bg-white` con dentro, in
ordine, `Ui::TableToolbarComponent` (`framed: true`) → `Ui::TableComponent` → `Ui::PaginationComponent`
(C27, C50, T5). Esempio completo: skill `closeyourit-design-system`, `table.md`. Galleria mockup in
`docs/mockups/components/` (`data-table.html`).

### `Ui::EntityMarkComponent`
Marchio visivo di un **progetto/gruppo** accanto al nome. `render Ui::EntityMarkComponent.new(record:, size:)`
(`record` risponde a `color`/`icon`/`icon_image`/`icon_kind` via concern `Iconable`; `size:` `:sm` default o `:xs`).
Precedenza (`Iconable#icon_kind`): **immagine caricata** (tile `<img object-cover>`) → **icona Lucide**
(chip col tint `Ui::Colors.chip(color)` + `Ui::IconComponent`) → **tile pieno col colore** (`Ui::Colors.swatch`, fallback).
Usato in `member/projects/_project_row`, `_cards`, `_overview_header`, `member/groups/index`, `groups/show`.
Form: il picker icona/colore è in `member/shared/_icon_field` + `_color_field` (Stimulus `ui--picker` su `<input hidden>`).

### `Ui::GithubStatusComponent`
Indicatore compatto dello stato repository del progetto.
`render Ui::GithubStatusComponent.new(connected:, size: :sm, test_id:)`
- `connected: true` → marchio GitHub `zinc-900` con check `emerald-600`.
- `connected: false` → marchio `gray-300` con minus `gray-400`.
- `size:` accetta `:sm` (card, default) e `:lg` (header progetto).
- Check/minus, `aria-label` e tooltip i18n rendono lo stato comprensibile senza dipendere dal solo colore.

### `Ui::TooltipComponent`
Pallino da **12px** (`w-3 h-3`) che al passaggio del mouse **o al focus da tastiera** apre un popup con
testo esplicativo. Cablato allo Stimulus **`ui--tooltip`**: il pannello è posizionato con `position: fixed`
calcolato da `getBoundingClientRect` (flip verticale + clamp orizzontale), così **sfugge all'overflow di
tabelle e a `<dialog>` senza essere clippato**; chiude su Esc, `mouseleave`/`blur` e click-fuori. Senza JS
resta il fallback statico (classi `bottom-full`/`top-full`) e il testo è comunque annunciato via `aria-describedby`.
`render Ui::TooltipComponent.new(text:, title: nil, icon: nil, tone: :dark, placement: :top, test_id:)`
- `text`/`title` arrivano già tradotti (`t(...)`); `title` è la riga in grassetto sopra il testo.
- `tone` = variante semantica (tono ignoto → `ArgumentError`):
  - `:dark` (default) — pallino `bg-sky-500`, "i" bianca. **Informazione**: "cos'è questa cosa".
  - `:tip` — pallino `bg-emerald-100 text-emerald-700`, icona **lampadina**. **Suggerimento/consiglio d'uso**.
  - `:muted` — solo icona grigia, senza pallino pieno.
- `icon`: nome Lucide. Default per tone (`info` per dark/muted, `lightbulb` per tip); il caller può forzarlo.
- `placement`: `:top` (default) o `:bottom`.
- Il trigger è un `<button>` focusabile (a11y da tastiera); il pannello è `role="tooltip"` nascosto via **attributo `[hidden]`** (mai `.hidden` — TS-TAILWIND-001).
- In `PageHeaderComponent`: `title_tooltip:` rende la "i" informativa accanto al titolo (solo Valhalla, CYRA-883).
- Usato in: header SMART server, clausole Given/When/Then/Expected del bug, fingerprint errori/metriche, SLA uptime, header Ingest tokens.

### Componenti senza scheda estesa

- **`Ui::AuditMetaComponent`** — striscia "Creato / Aggiornato" (data + autore) su una riga che va a capo, con slot `action` in coda per "Cronologia"; non disegna un pannello suo. Il caller calcola date e nomi. DESIGN.md E22.
- **`Ui::ChangelogComponent`** — in fondo alla sidebar: la versione (mono) apre un `<dialog>` con le ultime release e il link allo storico. DESIGN.md I18.
- **`Ui::ChangelogReleaseComponent`** — una release del changelog: versione, data e sezioni; le voci lunghe si ripiegano dietro «continua». Usato dal dialog e dalla pagina storico.
- Signed measurements opt in with `bar.bottom` (percentage from the plot bottom) and `gridline.baseline: true`. Height is the absolute magnitude from zero; known zero retains a one-pixel marker. Missing samples remain hatched, and an entirely missing range uses the empty note. Legacy callers omit these keys.
- **`Ui::HistogramComponent`** — istogramma "Occorrenze nel tempo" di errori e metriche: gutter Y, gridline, asse X, riassunto sr-only, tooltip flottante. Solo layout: i dati arrivano dai view-model.
- **`Ui::MeterComponent`** — barra "etichetta · riempimento · valore" dei dettagli server (sensori, CPU, rete, swap, disco). Colori letterali, fuori mappa ripiega sul neutro.
- **`Ui::PasswordRulesComponent`** — checklist delle regole password che si spuntano mentre si scrive (Stimulus `ui--password-rules`, `aria-live`). DESIGN.md H18.

## Pattern inline (no componente dedicato)

- **Dot colore secondari** (colonna board, dot di gruppo inline nelle righe, status/priority): inline con
  `Ui::Colors.swatch(color)` (`app/constants/ui/colors.rb`) — classi **letterali** in un `.rb`
  (Tailwind v4 scansiona i `.rb`), mai interpolate. Il marchio **primario** di progetto/gruppo usa invece
  `Ui::EntityMarkComponent` (sopra). I **badge** status/priority usano `Ui::BadgeComponent`.
- **Avatar**: inline con l'helper `avatar_initials(name)` (cerchio iniziali) o icona "non assegnato".
