# frozen_string_literal: true

# CYRA-638 — un contratto si giudica con le regole che DICHIARA.
#
# I nostri schemi dichiarano i `pattern` in ECMA-262, dove `^` e `$` legano l'intera stringa.
# `JSONSchemer.schema` senza `regexp_resolver` usa invece la semantica Ruby, dove sono ancore di RIGA:
# un valore giusto seguito da un a capo e da qualunque altro testo passa per buono. Un controllo che
# dice di verificare il contratto e lo verifica con altre regole è verde e non verifica niente — ed è
# il tipo di verde che nessuno va a riaprire.
#
# La regola sta qui e in un posto solo: prima viveva copiata in tre contract spec, ed è così che due
# delle tre copie sono rimaste indietro quando CYAU-173 ha sistemato la terza (e il servizio che
# valida davvero, Agents::Attempts::Deliver).
module ContractSchemer
  def contract_errors(schema, definition, document)
    validator = JSONSchemer.schema(
      { "$schema" => schema.fetch("$schema"),
        "$defs" => schema.fetch("$defs"),
        "$ref" => "#/$defs/#{definition}" },
      regexp_resolver: "ecma"
    )
    validator.validate(document).to_a
  end
end

RSpec.configure { |config| config.include ContractSchemer }
