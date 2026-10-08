# frozen_string_literal: true

# Read gate shared by the cyi skills endpoints (CYRA-912): manage implies view, as for the skill bundle.
module SkillReleaseAccess
  private

  def require_view
    return true if authorization.can?("agents.view") || authorization.can?("agents.manage")

    render_error("R403-CLIAUTH-002", "Permission denied", status: :forbidden)
    false
  end
end
