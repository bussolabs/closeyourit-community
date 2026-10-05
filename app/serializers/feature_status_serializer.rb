# frozen_string_literal: true

# Stato di una cella della matrice (Types::FeatureStatus), lookup org-scoped. `category` è la
# semantica del ciclo di vita (unplanned/planned/in_development/available/deprecated/not_applicable):
# è quella, non la label rinominabile, che dice se ci si aspetta una versione.
class FeatureStatusSerializer < ApplicationSerializer
  attributes :id, :code, :label, :color, :position, :active, :category
end
