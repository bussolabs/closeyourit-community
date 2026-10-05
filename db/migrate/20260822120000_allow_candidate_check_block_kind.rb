# frozen_string_literal: true

# CYRA-614 — un terzo autore del blocco: il sistema è andato ad aprire la proposta e ha trovato
# qualcosa che non va (controlli rossi, proposta assente, ramo di destinazione sbagliato, repository
# non collegato).
#
# Serve un `kind` suo perché da lì dipende la frase che legge chi deve decidere: quella del tetto
# nomina la revisione e conta le bocciature — che qui sono zero, perché la consegna era valida — e
# quella dell'agente riporta un motivo che l'agente non ha scritto.
class AllowCandidateCheckBlockKind < ActiveRecord::Migration[8.1]
  VECCHIO = "blocked_kind IS NULL OR blocked_kind::text = ANY (ARRAY['attempt_limit'::character varying, 'agent_blocked'::character varying]::text[])"
  NUOVO = "blocked_kind IS NULL OR blocked_kind::text = ANY (ARRAY['attempt_limit'::character varying, 'agent_blocked'::character varying, 'candidate_check'::character varying]::text[])"

  def up
    remove_check_constraint :agents_workflows, VECCHIO, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, NUOVO, name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, NUOVO, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, VECCHIO, name: "agents_workflows_blocked_kind_valido"
  end
end
