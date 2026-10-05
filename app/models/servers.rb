# frozen_string_literal: true

module Servers
  # Dominio server monitoring (metriche di sistema push-ate da closeyourit-agent).
  # Radice org-scoped: un host fisico non appartiene a un progetto. Tabelle prefissate `servers_`.
  def self.table_name_prefix
    "servers_"
  end
end
