# frozen_string_literal: true

# CYRA-799 — che cosa vede, di ogni dominio, chi sta guardando: UN oggetto che la pagina riceve
# (`visible`), non venticinque metodi che eredita senza sapere da dove arrivino. Gli elenchi vivono
# in Authorization::VisibleScope; qui resta il filo che lo lega alla richiesta.
module VisibleResources
  extend ActiveSupport::Concern

  included do
    helper_method :visible
  end

  private

  # Uno per richiesta: le pluck del linkage (owner check, group/project/team ids) girano una volta
  # sola per quante volte lo si interroghi — è quello che tiene fuori gli N+1 (prosopite).
  def visible
    @visible ||= Authorization::VisibleScope.new(
      account: Current.account,
      organization: Current.organization,
      # Il ramo che scavalca il linkage segue chi guarda DAVVERO: regge l'impersonation.
      true_account: Current.true_account,
      # Server e gruppi uptime sono org-level: chi li vede lo decide un permesso, e la regola di quel
      # permesso resta a PermissionGates. Qui passa il verdetto, chiesto solo se serve.
      permits_area: ->(area) { can_view_area?(area) }
    )
  end
end
