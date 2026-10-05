# frozen_string_literal: true

# CYRA-625 — sei progetti non mettono online un sito: pubblicano un pacchetto che altre persone poi
# installano. Per quelli «fatto» è quello che il magazzino pubblico mostra a chi installa, e per
# andarlo a guardare servono due coordinate che il sistema non ha mai avuto in casa: su quale
# scaffale, e con che nome.
#
# Senza, l'unica strada sarebbe indovinare il nome dal repository — e il nome del pacchetto non è
# quasi mai quello del repository.
class AddRegistryCoordinatesToGithubRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :github_repositories, :registry, :integer
    add_column :github_repositories, :package_name, :string

    # Chi dichiara «il pacchetto compare sullo scaffale» deve dire su quale e con che nome: senza,
    # la prova non si può nemmeno comporre, e la lavorazione resterebbe ferma a chiedersi dove
    # guardare. Vale nei DUE sensi, come per l'ambiente di produzione: non si tolgono le coordinate a
    # un progetto che ha già fatto quella scelta.
    add_check_constraint :github_repositories,
                         "release_probe <> 1 OR (registry IS NOT NULL AND package_name IS NOT NULL)",
                         name: "github_repositories_publish_needs_registry"
    add_check_constraint :github_repositories,
                         "registry IS NULL OR registry = ANY (ARRAY[0, 1, 2, 3, 4])",
                         name: "github_repositories_registry_known"
  end
end
