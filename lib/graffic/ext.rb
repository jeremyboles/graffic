# TODO: Document this better and figure out how to handle this with a module
class Graffic < ActiveRecord::Base
  class << self
    def class_inheritable_writer_with_default(*syms)
      class_inheritable_writer_without_default(*syms)
      if syms.last.is_a?(Hash) && default = syms.last.delete(:default)
        syms.flatten.each do |sym|
          next if sym.is_a?(Hash)
          send(sym.to_s + '=', default)
        end
      end
    end
    alias_method_chain :class_inheritable_writer, :default
  end
end