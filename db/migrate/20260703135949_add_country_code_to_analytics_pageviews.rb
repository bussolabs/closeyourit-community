class AddCountryCodeToAnalyticsPageviews < ActiveRecord::Migration[8.1]
  def change
    add_column :analytics_pageviews, :country_code, :string
  end
end
