# frozen_string_literal: true

module ApplicationHelper
  def mask_secret(value, visible: 12)
    text = value.to_s
    return "—" if text.blank?
    return "#{'*' * 8}" if text.length <= visible

    "#{text[0, visible]}…#{'*' * 12}"
  end

  def redis_status_label(ok)
    ok ? "已连接" : "连接失败"
  end
end
