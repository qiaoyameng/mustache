class Mustache
  # Base class for all errors raised while resolving or rendering a
  # dynamic partial ({{>*name}}).
  class DynamicPartialError < StandardError; end

  # Raised when the variable holding a dynamic partial name cannot
  # be found in the context.
  class DynamicPartialNameMissing < DynamicPartialError; end

  # Raised when a dynamic partial name resolves to something that is
  # not a String. The value is never implicitly converted (no `to_s`,
  # no Proc calls) to protect against unexpected code execution.
  class DynamicPartialNameInvalid < DynamicPartialError; end

  # Raised when a dynamic partial name resolves to an empty string.
  class DynamicPartialNameEmpty < DynamicPartialError; end

  # Raised when a dynamic partial name is not registered in the
  # caller-provided `dynamic_partials` mapping.
  class DynamicPartialNameNotRegistered < DynamicPartialError; end

  # Raised when dynamic partials recurse beyond the allowed depth.
  class DynamicPartialRecursionError < DynamicPartialError; end
end
