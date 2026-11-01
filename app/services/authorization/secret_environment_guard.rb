# frozen_string_literal: true

module Authorization
  # Guard anti privilege-escalation sul confine AMBIENTI dei secret (CYRA-1118): "non puoi aprire ad
  # altri — né a te stesso — ambienti che non vedi". Gemello di Authorization::ScopeGuard (progetti e
  # gruppi): qui il confine è quello di Secrets::EnvironmentAccess dell'attore.
  #
  # Una allow-list VUOTA vale "nessun limite": non è la lista degli ambienti di oggi, è anche ogni
  # ambiente che l'org creerà domani. Il confine illimitato resta quindi UNLIMITED e non si espande mai
  # ai code attuali — altrimenti, con un solo ambiente, svuotare una lista finita sembrerebbe non aprire
  # niente e diventerebbe accesso a tutto alla nascita del secondo.
  #
  # Il confronto è sul confine EFFETTIVO, progetto per progetto (override, altrimenti org-wide): una
  # modifica org-wide cambia anche i progetti senza override del target, dove l'attore può essere più
  # stretto che a livello org. Si controllano il livello org (vale per i progetti senza override di
  # nessuno dei due e per quelli futuri) e ogni progetto con un override del target, prima o dopo, o
  # dell'attore.
  #
  # Restringere è sempre lecito; si rifiuta solo ciò che il nuovo confine APRE (non aperto prima al
  # target) e che l'attore non vede. Gli ambienti che il target aveva già restano ammessi: riconfermarli
  # non è una scalata. actor nil (seed/system) o unscoped (owner/god) → nessun vincolo.
  class SecretEnvironmentGuard
    UNLIMITED = :unlimited

    # Il confine di un account in un'org: allow-list org-wide (vuota = nessun limite) e override per
    # progetto ({ project_id => code }, vuoto = eredita l'org-wide).
    Boundary = Data.define(:org_wide, :overrides) do
      def self.of(account:, organization:)
        membership = Connections::Membership.find_by(account_id: account.id, organization_id: organization.id)
        return if membership.nil?

        overrides = Connections::AccountSecretAccess.where(account_id: account.id, organization_id: organization.id)
                                                    .pluck(:project_id, :environment_codes).to_h
        new(org_wide: membership.secret_environment_codes || [], overrides: overrides)
      end

      # UNLIMITED o la lista finita che vale sul progetto (nil = livello org).
      def effective(project_id)
        codes = (project_id && overrides[project_id].presence) || org_wide.presence
        codes || UNLIMITED
      end
    end

    # requested/current: Boundary con code già sanificati. current nil = il target non aveva alcun
    # accesso (creazione). Ritorna l'AppError R403-ACCESS-001 da propagare, o nil.
    def self.barrier(actor:, organization:, requested:, current:)
      return if actor.nil? || Authorization::VisibleScope.unscoped?(account: actor, organization: organization)

      actor_boundary = Boundary.of(account: actor, organization: organization)
      project_ids = [ requested, current, actor_boundary ].compact.flat_map { |boundary| boundary.overrides.keys }

      [ nil, *project_ids.uniq ].each do |project_id|
        opened = opened(requested.effective(project_id), current&.effective(project_id))
        # Senza membership nell'org l'attore non vede niente (fail-closed, mai "tutti").
        allowed = actor_boundary ? actor_boundary.effective(project_id) : []
        forbidden = forbidden(opened, allowed)
        return error(forbidden, allowed, organization, project_id) if forbidden.present?
      end
      nil
    end

    # Ciò che `after` apre rispetto a `before` (nil = nessun accesso). Da un confine finito a UNLIMITED
    # si apre UNLIMITED anche se oggi coprono gli stessi ambienti.
    def self.opened(after, before)
      return [] if before == UNLIMITED
      return UNLIMITED if after == UNLIMITED

      after - Array(before)
    end
    private_class_method :opened

    def self.forbidden(opened, allowed)
      return [] if allowed == UNLIMITED
      return UNLIMITED if opened == UNLIMITED

      opened - allowed
    end
    private_class_method :forbidden

    def self.error(forbidden, allowed, organization, project_id)
      unlimited = forbidden == UNLIMITED
      codes = unlimited ? organization.environments.pluck(:code) - allowed : forbidden
      message = if unlimited
        "Non puoi togliere il limite agli ambienti dei segreti: tu non li vedi tutti"
      else
        "Non puoi aprire ambienti dei segreti che non vedi: #{codes.sort.join(', ')}"
      end

      AppError.new(
        message, code: "R403-ACCESS-001", status: :forbidden,
        details: { forbidden_environment_codes: codes.sort, unlimited: unlimited || nil, project_id: project_id }.compact
      )
    end
    private_class_method :error
  end
end
