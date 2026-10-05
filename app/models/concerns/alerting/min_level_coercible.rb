# frozen_string_literal: true

module Alerting
  # min_level è una colonna INTERA, confrontata numericamente col level dell'evento (Errors::Group /
  # Logs::Entry) in Alerting::Evaluate. Il canale Member manda già l'intero (value delle option); i
  # canali API (CLI/SDK/agent/curl) mandano invece il NOME del livello ("error"). Il cast Rails di una
  # stringa non numerica dà "error".to_i == 0 (debug): supererebbe la validazione e salverebbe l'OPPOSTO
  # di quanto chiesto — in silenzio (CYRA-236). Qui il nome noto viene convertito nell'intero PRIMA del
  # cast (normalizes gira DOPO il cast, troppo tardi; un enum vero romperebbe Rule::LEVELS.key(min_level)
  # nelle view e @level >= min_level in Evaluate). Un nome sconosciuto passa grezzo e cade in validazione
  # con un errore chiaro, così un valore qualsiasi non viene mai persistito.
  module MinLevelCoercible
    extend ActiveSupport::Concern

    included do
      validates :min_level, inclusion: { in: Errors::Group.levels.values }, allow_nil: true
      validate :min_level_name_must_exist
    end

    # Intero (Member) → invariato; nome del livello ("error" → 3) → intero. Nome sconosciuto e stringa
    # numerica passano grezzi: il primo cade nella validazione custom, la seconda nell'inclusion sul
    # valore castato. Nessuno stato d'istanza: la validazione legge il before_type_cast, che reload e
    # rollback ripristinano al valore del DB (un record ricaricato con dati validi torna valido).
    def min_level=(value)
      super(coerce_min_level(value))
    end

    private

    def coerce_min_level(value)
      return value unless value.is_a?(String)
      return nil if value.strip.empty?

      Errors::Group.levels[value.strip] || value
    end

    # Un nome di livello indicato ma inesistente ("bogus") non deve diventare 0 in silenzio: si guarda il
    # valore grezzo assegnato (before_type_cast) e, se è un nome non numerico non riconosciuto, R422.
    def min_level_name_must_exist
      raw = min_level_before_type_cast
      return unless raw.is_a?(::String)

      name = raw.strip
      return if name.empty? || name.match?(/\A-?\d+\z/)
      return if Errors::Group.levels.key?(name)

      errors.add(:min_level, :not_a_level, value: name, allowed: Errors::Group.levels.keys.join(", "))
    end
  end
end
