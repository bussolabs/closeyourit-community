# frozen_string_literal: true

module Errors
  # Smistamento di un gruppo errore (resolve/ignore/reopen). Specializza Observability::Triage con
  # l'audit di regressione release-aware (CYRA-44) e le note di risoluzione cause/fix (CYRA-192).
  # Condiviso da API, CLI e UI Member.
  class Triage < Observability::Triage
    # resolved_release: :auto (default) → calcola la release live dal DB; una version esplicita (o nil)
    # la usa così com'è, senza query — lo passa Errors::BulkTriage per evitare l'N+1 su projects_releases
    # quando risolve N gruppi (uno stesso progetto = una sola live_version, precalcolata a monte).
    # cause/fix (CYRA-192): perché l'errore c'era e cosa l'ha chiuso. Accettati SOLO sulla resolve —
    # su ignore o reopen non avrebbero senso, e su reopen si cancellano di proposito (vedi
    # resolution_notes): un gruppo riaperto non è più risolto, tenersi la vecchia spiegazione
    # racconterebbe una bugia a chi lo ritrova.
    def initialize(group:, action:, resolved_release: :auto, cause: nil, fix: nil)
      super(group:, action:)
      @resolved_release = resolved_release
      @cause = cause
      @fix = fix
    end

    private

    def invalid_action_code = "R422-ERROR-002"

    def extra_attributes(target)
      { **regression_audit(target), **resolution_notes(target) }
    end

    # Sulla resolve scrive le note SOLO se passate: una risoluzione rapida senza spiegazione non deve
    # cancellare quella scritta la volta prima. Sulla riapertura invece si azzerano sempre.
    def resolution_notes(target)
      return { resolution_cause: nil, resolution_fix: nil } if target == :unresolved
      return {} unless target == :resolved

      {}.tap do |attrs|
        attrs[:resolution_cause] = @cause if @cause.present?
        attrs[:resolution_fix] = @fix if @fix.present?
      end
    end

    # CYRA-44: sulla resolve fotografa la release "del fix" (la live). Un evento successivo con
    # release precedente è un residuo di client vecchio (non regressione); solo una release pari o
    # successiva riapre il gruppo. Azzera regressed_in_release: inizia un nuovo ciclo di risoluzione.
    def regression_audit(target)
      return {} unless target == :resolved

      release = @resolved_release == :auto ? Projects::Release.live_version(@group.project) : @resolved_release
      { resolved_in_release: release, regressed_in_release: nil }
    end
  end
end
