# frozen_string_literal: true

# Quale gruppo della sidebar contiene la pagina aperta. Erede di SpaceContext, ridotto a una frazione
# (CYRA-521): lo space decideva QUALI voci mostrare, e da lì nasceva il menu che si riscriveva sotto le
# dita; il gruppo decide solo due cose innocue — quale accordion parte aperto e cosa scrive la briciola
# di pane al livello dell'area. Nessuna sessione, nessuna preferenza, nessuna query: solo la pagina.
module GroupContext
  extend ActiveSupport::Concern

  included do
    helper_method :current_group
  end

  private

  # Gruppo della pagina corrente, o nil per una pagina che non appartiene a nessuno. Le panoramiche
  # (member/overviews) lo prendono dal group_id di route, che Navigation::Group.find valida contro il
  # registro: un id manomesso ricade sulla Home invece di far esplodere la pagina.
  def current_group
    @current_group ||=
      if controller_path == "member/overviews"
        Navigation::Group.find(params[:group_id])
      else
        Navigation::Group.for_controller(controller_path)
      end
  end
end
