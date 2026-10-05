# Flag per-progetto: attiva la modalità rapida del form bug (campo libero + assistente AI che
# compila i 4 campi Given/When/Then/Expected). Default OFF → comportamento attuale invariato.
class AddQuickBugReportEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :quick_bug_report_enabled, :boolean, default: false, null: false
  end
end
