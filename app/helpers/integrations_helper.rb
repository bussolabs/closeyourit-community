# frozen_string_literal: true

# Come si legge in pagina lo stato dei servizi collegabili (CYRA-545).
#
# La domanda «questa organizzazione ha collegato quel servizio?» non si fa più da nessuna view
# (CYRA-765): l'unica funzione appoggiata a una chiave di organizzazione è la misura della velocità
# dei siti, che quando la chiave manca lo dice nella propria pagina, con i propri dati sotto gli
# occhi. Un helper senza chiamanti sarebbe un invito a rifare un ramo che non serve più.
module IntegrationsHelper
  # Lo stato di un servizio nella pagina Integrazioni (CYRA-545). Quattro casi e non tre: «collegato
  # ma mai provato» non è «collegato» — nasce così la credenziale adottata dall'operatore
  # (`Integrations::AdoptSystemKeys`), che il giro giornaliero prova entro il giorno dopo — e non è
  # nemmeno «rotto», perché nessuno ha ancora detto che quella chiave non vada bene.
  def integration_state(credential)
    return :missing if credential.nil?
    return :broken if credential.broken?

    credential.verified? ? :connected : :unverified
  end

  INTEGRATION_STATE_COLORS = {
    connected: :emerald, broken: :red, unverified: :amber, missing: :gray
  }.freeze

  def integration_state_color(state) = INTEGRATION_STATE_COLORS.fetch(state, :gray)

  # Il colore dichiarato dal registro dei servizi, tradotto in classi LETTERALI: lo scanner di
  # Tailwind purga tutto ciò che è interpolato (`bg-#{color}-50` non arriverebbe nel CSS), e un
  # colore fuori mappa ricade sul neutro invece di lasciare un riquadro senza sfondo.
  INTEGRATION_TONES = {
    "violet" => "bg-violet-50 dark:bg-violet-500/15 text-violet-600 dark:text-violet-400",
    "amber" => "bg-amber-50 dark:bg-amber-500/15 text-amber-600 dark:text-amber-400",
    "sky" => "bg-sky-50 dark:bg-sky-500/15 text-sky-600 dark:text-sky-400",
    "indigo" => "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-600 dark:text-indigo-400",
    "emerald" => "bg-emerald-50 dark:bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
  }.freeze

  INTEGRATION_TONE_FALLBACK = "bg-stone-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400"

  def integration_tone(color) = INTEGRATION_TONES.fetch(color.to_s, INTEGRATION_TONE_FALLBACK)

  # Le funzioni che un servizio accende, con i nomi che si leggono in pagina. Sono le stesse che si
  # spengono scollegandolo: la conferma le ripete una per una, perché scollegare senza sapere cosa si
  # ferma è la scelta che nessuno può prendere bene.
  def integration_features(provider)
    provider.features.map { |feature| t("integrations.features.#{feature}") }
  end
end
