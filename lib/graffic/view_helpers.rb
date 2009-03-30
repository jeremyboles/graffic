module Graffic::ViewHelpers
  def graffic_tag(graffic, version_or_opts = {}, opts = {})
    if graffic && graffic.state.eql?('processed')
      if version_or_opts.is_a?(Symbol)
        graffic_tag(graffic.try(version_or_opts), opts)
      else
        
        image_tag(graffic.url, { :size => graffic.size }.merge(version_or_opts))
      end
    end
  end
end

ActionView::Base.send :include, Graffic::ViewHelpers