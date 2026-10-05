# frozen_string_literal: true

module Errors
  # Regola di raggruppamento personalizzata di un progetto (CYRA-153). All'ingest
  # (Errors::ApplyGroupingRules) la PRIMA regola attiva, in ordine di position, che soddisfa il match
  # rimappa il fingerprint dell'occorrenza: tutte quelle che colpiscono regole con lo STESSO
  # fingerprint_key confluiscono in un unico gruppo. È così che il team piega il grouping automatico.
  class GroupingRule < ApplicationRecord
    self.table_name = "errors_grouping_rules"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :error_grouping_rules

    # Campo dell'occorrenza osservato (estratto da Errors::PayloadFields) e come confrontarlo:
    # vocabolario tecnico fisso → enum legittimo (rules/lookup-tables.md). `field`/`operator` col
    # prefisso per non collidere con nulla (incluso il metodo `transaction` di AR).
    enum :field, { exception_type: 0, message: 1, culprit: 2, transaction: 3 }, prefix: :field
    enum :operator, { contains: 0, equals: 1, starts_with: 2 }, prefix: :op

    validates :value, presence: true
    validates :fingerprint_key, presence: true
    validates :position, numericality: { only_integer: true }
    # active è NOT NULL: un valore booleano non riconoscibile lo casterebbe a nil e sfonderebbe il
    # vincolo con un 500. La inclusion lo intercetta come 422 onesto (field/operator li guarda il controller).
    validates :active, inclusion: { in: [ true, false ] }

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :created_at) }

    # Il match è case-insensitive e SENZA regex: sul path caldo dell'ingest una regex fornita
    # dall'utente sarebbe una porta aperta al ReDoS. `fields` è l'hash di Errors::PayloadFields.
    def matches?(fields)
      subject = fields[field.to_sym].to_s
      return false if subject.blank?

      needle = value.to_s
      case operator
      when "contains"    then subject.downcase.include?(needle.downcase)
      when "equals"      then subject.casecmp?(needle)
      when "starts_with" then subject.downcase.start_with?(needle.downcase)
      else false
      end
    end

    # Fingerprint deterministico della regola: due regole con lo stesso fingerprint_key convergono
    # sullo stesso gruppo. Lo scope [project_id, fingerprint] del gruppo tiene isolati i tenant.
    def target_fingerprint = Digest::SHA256.hexdigest("grouping-rule:#{fingerprint_key}")
  end
end
