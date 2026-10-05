# frozen_string_literal: true

# Colonna di un dataset (Datasets::Column) per la CLI: è lo SCHEMA, cioè il contratto che il
# chiamante deve rispettare per scrivere una riga — `code` è la chiave con cui si mandano valori e
# foto, `kind` dice che forma ha il valore, `role` se è un dato fornito (input) o un attributo da
# predire (target), `options` lo spazio dei valori ammessi per le categorie.
class DatasetColumnSerializer < ApplicationSerializer
  attributes :id, :code, :label, :position, :required

  attribute(:kind)    { |column| column.kind }
  attribute(:role)    { |column| column.role }
  attribute(:options) { |column| column.option_values }
end
