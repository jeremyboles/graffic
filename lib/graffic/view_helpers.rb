module Graffic::ViewHelpers
  def graffic_tag(graffic, version_or_opts = {}, opts = {})
    if graffic && graffic.state.eql?('processed')
      if version_or_opts.is_a?(Symbol)
        graffic_tag(graffic.try(version_or_opts), opts)
      else
        image_tag(graffic.url, version_or_opts.merge(:size => graffic.size))
      end
    end
  end
end

ActionView::Base.send :include, Graffic::ViewHelpers