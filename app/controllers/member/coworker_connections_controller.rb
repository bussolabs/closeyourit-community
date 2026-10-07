module Member
  # Apps a Puck may use and the sites it may log in to (CYRA-1014, CYRA-1015). Tokens and passwords
  # are written here and never shown again.
  class CoworkerConnectionsController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: connections only shape what the owner's Puck can reach (CYRA-1014)"

    def create
      connection = coworker_puck.connections.new(params.require(:connection).permit(:provider, :name, :url, :token, :access))
      connection.name = "GitHub" if connection.provider == "github"
      connection.save!
      refresh_tools(connection)
      back
    rescue ActiveRecord::RecordInvalid
      back(alert: t("member.coworkers.invalid"))
    end

    def update
      refresh_tools(coworker_puck.connections.find(params[:id]))
      back
    end

    def destroy
      coworker_puck.connections.find(params[:id]).destroy!
      back
    end

    private

    def refresh_tools(connection)
      return unless connection.provider == "mcp"

      connection.update!(tools: Coworkers::Mcp.list_tools(connection), last_error: nil)
    rescue Coworkers::Mcp::Error => e
      connection.update!(last_error: e.message.first(200))
    end

    def back(**options) = redirect_to(member_coworker_path(coworker_puck, panel: "rules"), status: :see_other, **options)
  end
end
