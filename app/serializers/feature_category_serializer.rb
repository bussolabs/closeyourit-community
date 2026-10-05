# frozen_string_literal: true

# Categoria della matrice (riga-gruppo: "Auth", "Notifiche"). Le funzionalità NON sono qui dentro:
# la matrice le annida da sé (Product::MatrixSnapshot), gli altri endpoint le espongono a parte.
class FeatureCategorySerializer < ApplicationSerializer
  attributes :id, :name, :position
end
