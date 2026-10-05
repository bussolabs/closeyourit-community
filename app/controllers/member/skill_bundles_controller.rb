# frozen_string_literal: true

module Member
  # Pagina "Skill bundle" (space automation): vetrina + override manuale del pin del bundle skill (singleton
  # per org). Normalmente lo aggiorna la CI di closeyourit-skills al tag (PUT /cli/v1/agents/skill_bundle);
  # qui l'utente lo vede e — se serve — lo forza a mano.
  #
  # CYRA-453 — pagina di AMMINISTRAZIONE, non di lettura: quattro campi obbligatori e una spunta che
  # riporta le macchine a una versione più vecchia. Sta dietro `agents.manage` (non più agents.view) e
  # fuori dal menu: si raggiunge dalla pagina delle macchine e dalla scheda dell'area, entrambe gated
  # sullo stesso permesso. Chi guarda le automazioni lavorare non ha motivo di trovarsi qui.
  class SkillBundlesController < Member::BaseController
    before_action -> { require_permission!("agents.manage") }

    # CYRA-924 — every column sorts (C9); a handful of machines, sorted in memory.
    version = ->(value) { Gem::Version.correct?(value.to_s) ? Gem::Version.new(value) : nil }
    CONFORMANCE_SORT_COLUMNS = {
      "host" => ->(row) { row.host.hostname.to_s.downcase },
      "expected" => ->(row) { version.(row.expected) },
      "actual" => ->(row) { version.(row.actual) },
      "state" => ->(row) { row.state.to_s }
    }.freeze

    def show
      @bundle = current_organization.skill_bundle
      @conformance = skill_bundle_conformance
      @conformance_rows = sorted_rows(@conformance.rows, columns: CONFORMANCE_SORT_COLUMNS)
    end

    def update
      # `force` (checkbox del form): consente un rollback INTENZIONALE a una versione più vecchia, bypassando
      # il guard anti-downgrade. Assente = pin normale monotonico. Il Pin normalizza la stringa a booleano.
      result = ::Agents::SkillBundles::Pin.call(
        organization: current_organization,
        repo: params[:repo], ref: params[:ref], version: params[:version], digest: params[:digest],
        force: params[:force]
      )
      if result.ok?
        redirect_to member_skill_bundle_path, notice: t("member.skill_bundle.saved")
      else
        # Query fresca: il Pin fallito lascia in memoria un record non persistito (updated_at nil); la vetrina
        # deve mostrare il pin realmente salvato, non gli attributi sporchi. Il form ripopola dai params.
        @bundle = ::Agents::SkillBundle.find_by(organization: current_organization)
        @conformance = skill_bundle_conformance
        @errors = result.error.details.presence || { base: [ result.error.message ] }
        render :show, status: :unprocessable_content
      end
    end

    private

    # CYRA-453 — la tabella in cima: cosa sta usando DAVVERO ogni macchina contro la versione fissata.
    # Fleet piccola (una manciata di Mac) e tutto già nella riga host (`runtimes` jsonb): una query,
    # nessun N+1. Le macchine revocate restano fuori: non eseguono più nulla.
    def skill_bundle_conformance
      ::Agents::SkillBundleConformance.new(
        bundle: @bundle, hosts: current_organization.agent_hosts.active.to_a
      )
    end
  end
end
