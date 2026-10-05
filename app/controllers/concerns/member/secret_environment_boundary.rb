# frozen_string_literal: true

module Member
  # Confine ambienti dell'attore sui secret di un progetto (CYRA-78/CYRA-268), estratto qui da CYRA-666.
  #
  # Il permesso dice COSA puoi fare, questo dice DOVE. La policy vive in Secrets::EnvironmentAccess ed è
  # la stessa del canale CLI: override per-progetto > allow-list org-wide > nessun limite.
  #
  # Perché è un concern e non tre copie. Fino a CYRA-666 questi tre metodi erano scritti inline in
  # ProjectSecretsController (:165-175) e ProjectSecretOverridesController (:81), e i due controller nati
  # dopo — i file segreto e lo storico versioni — non li hanno ereditati: sul web si scaricava la chiave
  # di produzione che il canale CLI negava con 403. Un confine di sicurezza copiato a mano si dimentica;
  # incluso, no.
  #
  # Cosa NON sta qui: la forma del rifiuto. Cambia per canale e per oggetto — JSON per le celle che si
  # sbloccano via fetch, 403 con la matrice ricaricata per i form, redirect per i file — e sui VALORI
  # scrive un evento di audit mentre sui FILE no (il vocabolario degli eventi dei file è un altro:
  # Secrets::AssetEvent::ACTIONS). Ogni controller compone la propria risposta; qui c'è solo la decisione.
  module SecretEnvironmentBoundary
    extend ActiveSupport::Concern

    private

    # Richiede `@project` già risolto dal controller (anti-BOLA a monte).
    def secret_access
      @secret_access ||= ::Secrets::EnvironmentAccess.new(account: Current.account, project: @project)
    end

    # Ambiente assente (nil) → negato quando la restrizione è attiva: fail-closed, come per i file
    # segreto senza ambiente. La decisione è di Secrets::EnvironmentAccess#allowed?.
    def environment_allowed?(environment) = secret_access.allowed?(environment&.code)

    # Gli id degli ambienti dell'ORGANIZZAZIONE su cui l'attore può operare. Il filtro parte dall'org e
    # non dagli ambienti dichiarati da questo progetto perché i file segreto delegati arrivano da altri
    # progetti: partendo dal progetto, un delegato consentito sparirebbe dall'elenco. Stesso criterio del
    # canale CLI (cli/v1/projects/secret_assets_controller.rb#allowed_environment_ids).
    def allowed_environment_ids
      ::Types::Environment.where(organization_id: Current.organization&.id,
                                 code: secret_access.restriction_codes).ids
    end

    # Il tentativo bloccato finisce nell'audit PRIMA del rifiuto: senza, chi bussa a un ambiente vietato
    # non lascia traccia da nessuna parte. `channel: "web"` distingue questo canale dalla CLI — una
    # lettura dal terminale non allarma nessuno, una dal browser sì. Vale sui VALORI, non sui file.
    def record_environment_denied(environment, name: nil)
      ::Secrets::RecordEvent.call(action: "denied", project: @project, environment: environment,
                                  actor: Current.account, name: name.presence, channel: "web")
    end
  end
end
