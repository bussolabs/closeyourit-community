class AddDeviceAndUtmDetailsToAnalyticsPageviews < ActiveRecord::Migration[8.1]
  def change
    add_column :analytics_pageviews, :device_type, :string
    add_column :analytics_pageviews, :browser_version, :string
    add_column :analytics_pageviews, :os_version, :string
    add_column :analytics_pageviews, :screen_class, :string
    add_column :analytics_pageviews, :utm_term, :string
    add_column :analytics_pageviews, :utm_content, :string
  end
end
