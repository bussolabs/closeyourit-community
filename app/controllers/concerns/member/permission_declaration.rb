# frozen_string_literal: true

module Member
  # CYRA-727 — ogni pagina dell'area utenti dice quale permesso controlla, o perché non ne serve uno.
  #
  # Il difetto che questa concern chiude non si vede usando il prodotto: i dati che una pagina mostra
  # sono già tagliati sul perimetro dell'account (`visible`, anti-BOLA), quindi una pagina
  # senza gate sembra corretta a chiunque la apra. Si vede solo dove si SCRIVE — un'azione che
  # modifica dati e non interroga nessun permesso non ha niente sotto: se domani la visibilità dello
  # scope si allarga, si allarga anche cosa quella pagina lascia fare, e nessuna prova diventa rossa.
  #
  # La rete è un `after_action`: se l'azione è arrivata in fondo senza che nessuno abbia interrogato i
  # permessi e senza un motivo scritto, in sviluppo e nelle prove è un errore. In produzione è un
  # warn: una dichiarazione dimenticata è un difetto del codice, non una ragione per chiudere in
  # faccia una pagina a chi la sta usando.
  #
  # Nota importante sul MOMENTO in cui si misura. `can?` è un helper delle viste, e la barra laterale
  # lo interroga per ogni voce di menu a ogni render: se non si chiudesse la finestra, ogni pagina
  # risulterebbe controllata solo per essersi disegnata, e questa rete non prenderebbe niente. Conta
  # quindi solo ciò che accade PRIMA del render — cioè il lavoro del controller, che è dove il gate
  # deve stare. Un gate che passa da un before_action che nega, invece, non arriva mai qui: quando un
  # before_action interrompe la catena Rails non esegue gli after_action.
  module PermissionDeclaration
    extend ActiveSupport::Concern

    # Alzata in sviluppo e nelle prove. Non ha un codice R4xx di prodotto di proposito: non è una
    # risposta che qualcuno deve leggere, è un errore di programmazione che nessun utente vedrà mai.
    class NotDeclared < StandardError; end

    # La chiave del motivo che vale per tutte le azioni del controller.
    EVERY_ACTION = "*"

    included do
      # L'ereditarietà è voluta: una base che dichiara il motivo lo passa ai figli (le azioni
      # dell'automazione, per esempio, sono tutte autorizzate dentro il proprio service).
      class_attribute :permission_exemptions, instance_writer: false, default: {}.freeze

      after_action :verify_permission_declared
    end

    class_methods do
      # Dichiara PERCHÉ questa pagina non passa da una chiave-permesso. Il motivo è obbligatorio e va
      # scritto per esteso: è quello che leggerà chi, fra un anno, si chiederà se qui manchi un gate.
      # Senza `only:` vale per tutte le azioni del controller.
      def permission_not_required(reason, only: nil)
        actions = only.nil? ? [ EVERY_ACTION ] : Array(only).map(&:to_s)
        self.permission_exemptions = permission_exemptions.merge(actions.index_with(reason.to_s)).freeze
      end
    end

    # Da qui in poi a interrogare i permessi è la vista, non il controller: quello che chiede la barra
    # laterale non vale come gate (vedi PermissionGates#note_permission_check!). Resta pubblico
    # come il `render` che sovrascrive: è la stessa porta, con un interruttore in più.
    def render(*, **, &)
      @permission_window_closed = true
      super
    end

    private

    # `permission_checked?` lo scrive chi interroga i permessi: vedi PermissionGates, che marca
    # dentro `can?` e chiude la finestra al primo render.
    def verify_permission_declared
      return if permission_checked? || permission_exemption_for(action_name)

      message = "#{self.class.name}##{action_name} non interroga nessun permesso e non dichiara " \
                  "perché non serve. Aggiungi il gate (require_permission!) oppure scrivi il motivo " \
                  "nel controller: permission_not_required \"…\", only: :#{action_name}"
      raise NotDeclared, message if Rails.env.local?

      Rails.logger.warn("CYRA-727 — #{message}")
    end

    def permission_exemption_for(action)
      permission_exemptions[action.to_s] || permission_exemptions[EVERY_ACTION]
    end
  end
end
