class AddRegressionReleasesToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    # Release live "del fix" al momento della resolve: un evento con release precedente è un
    # residuo di client vecchio (non regressione); solo una release >= questa riapre il gruppo.
    add_column :errors_groups, :resolved_in_release, :string,
               comment: "Release live quando il gruppo è stato risolto (audit di regressione)"
    # Release dell'evento che ha causato una VERA regressione (reopen legittimo): è ciò che
    # l'alert error_regression mostra, non la generica release più recente osservata.
    add_column :errors_groups, :regressed_in_release, :string,
               comment: "Release che ha causato il reopen su regressione confermata"
  end
end
