# frozen_string_literal: true

module Authorization
  # Strutture di rendering per lo schema what-if (diff current↔pending), prodotte da PreviewAccess::*.
  # Pure Data, nessuna logica di dominio: la UI (partial member/shared/_access_matrix) le consuma diretta.

  # Una riga = un progetto, con le chiavi scoped concesse ORA (current) e con i params pendenti (pending).
  MatrixRow = Data.define(:project, :current_keys, :pending_keys) do
    def added       = pending_keys - current_keys   # chiavi che la modifica AGGIUNGE
    def removed     = current_keys - pending_keys    # chiavi che la modifica TOGLIE
    def any_access? = current_keys.any? || pending_keys.any?
    def changed?    = added.any? || removed.any?
  end

  # Una cella org-level = una chiave, concessa ORA (current) e con i params pendenti (pending).
  OrgCell = Data.define(:key, :current, :pending) do
    def changed? = current != pending
  end

  # Diff per un soggetto (un account). Su team: uno per membro, con membership_change (:added/:removed/nil).
  MatrixDiff = Data.define(:subject, :rows, :org_cells, :membership_change) do
    def any_change?  = membership_change.present? || rows.any?(&:changed?) || org_cells.any?(&:changed?)
    def granted_rows = rows.select(&:any_access?)  # progetti con qualche accesso (current o pending)
    def empty_rows   = rows.reject(&:any_access?)  # progetti senza alcun accesso

    # Riepilogo dello stato PENDING (ciò che risulterebbe salvando).
    def pending_project_count = rows.count { |r| r.pending_keys.any? }
    def pending_action_count  = rows.sum { |r| r.pending_keys.size }
  end
end
