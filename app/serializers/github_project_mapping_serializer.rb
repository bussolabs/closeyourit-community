# frozen_string_literal: true

# Mapping minimale e stabile consumato dagli orchestratori locali: identifica il progetto
# CloseYourIt e, quando presente, il repository GitHub collegato. Non espone impostazioni di sync,
# environment o installation id che non servono alla discovery.
class GithubProjectMappingSerializer < ApplicationSerializer
  attribute :project_id, &:id
  attribute :project_key, &:key
  attribute :project_name, &:name

  attribute :repository do |project|
    repository = project.github_repository
    next nil unless repository

    { full_name: repository.full_name, default_branch: repository.default_branch }
  end
end
