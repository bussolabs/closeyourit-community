# frozen_string_literal: true

class AddSandboxToAgentsAgents < ActiveRecord::Migration[8.1]
  def change
    # Nullable per preservare i record Claude/shell esistenti; è obbligatoria soltanto per kind Codex.
    add_column :agents_agents, :sandbox, :string
  end
end
