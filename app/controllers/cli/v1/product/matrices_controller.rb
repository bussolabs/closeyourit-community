# frozen_string_literal: true

module Cli
  module V1
    module Product
      # Matrice funzionalità × piattaforme di un prodotto. index = i prodotti mappabili (i gruppi
      # visibili), show = la matrice intera in un payload solo (Product::MatrixSnapshot).
      #
      # Model SEMPRE fully-qualified (`::Product::…`) — vedi BaseController.
      class MatricesController < Cli::V1::Product::BaseController
        before_action :require_product_view
        before_action :set_matrix_group!, only: :show

        def index
          records, meta = paginate(visible_groups.ordered)
          render_ok(GroupSerializer.new(records), meta: meta)
        end

        def show
          render_ok(::Product::MatrixSnapshot.for(group: @group))
        end
      end
    end
  end
end
