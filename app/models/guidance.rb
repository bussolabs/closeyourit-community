# frozen_string_literal: true

# Guidance gerarchica di progetto (CYRA-74): references (puntatori a fonti di contesto) e procedures
# (istruzioni testuali) dichiarate ai livelli organizzazione → gruppo → progetto e RISOLTE da
# Guidance::Resolve, che è la fonte unica di ereditarietà e override. Non appartengono al ticket né al
# dominio AI: ticket, CLI, persone e automazioni consumano il contesto risolto, mai copiato altrove.
# Prefisso tabella del namespace (rules/rails/models.md): Guidance::Reference → guidance_references.
module Guidance
  def self.table_name_prefix = "guidance_"

  # Tipi ammessi come owner di una guidance: i tre livelli della gerarchia. Aggiungerne uno richiede
  # codice (Guidance::Resolve deve sapere dove inserirlo nella catena), quindi whitelist esplicita.
  OWNER_TYPES = %w[Organizations::Organization Projects::Group Projects::Project].freeze

  # owner_type → nome del livello esposto nel payload risolto ("origine e livello", DoD del ticket).
  LEVEL_BY_OWNER_TYPE = {
    "Organizations::Organization" => "organization",
    "Projects::Group" => "group",
    "Projects::Project" => "project"
  }.freeze

  # Chiave stabile: minuscole/cifre/punto/trattino/underscore, iniziale alfanumerica, ≤255 char. È
  # l'identità dello "slot" attraverso i livelli — org, gruppo e progetto usano la STESSA key per
  # ereditare/sovrascrivere/disabilitare lo stesso elemento.
  KEY_FORMAT = /\A[a-z0-9][a-z0-9._-]{0,254}\z/
end
