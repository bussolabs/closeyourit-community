class RestructureIdeasBodyToProblemSolution < ActiveRecord::Migration[8.1]
  # Il corpo libero unico dell'idea (body) diventa strutturato: problema (obbligatorio) +
  # soluzione (opzionale). Il contenuto esistente migra in `problem`. Reversibile.
  def up
    add_column :ideas_ideas, :problem, :text
    add_column :ideas_ideas, :solution, :text
    execute "UPDATE ideas_ideas SET problem = body"
    change_column_null :ideas_ideas, :problem, false
    remove_column :ideas_ideas, :body
  end

  def down
    add_column :ideas_ideas, :body, :text
    execute "UPDATE ideas_ideas SET body = problem"
    change_column_null :ideas_ideas, :body, false
    remove_column :ideas_ideas, :solution
    remove_column :ideas_ideas, :problem
  end
end
