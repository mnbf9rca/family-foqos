# frozen_string_literal: true

require 'optparse'

module LogPrivacy
  PRODUCTION_ROOTS = %w[
    Foqos
    FoqosWidget
    FoqosDeviceMonitor
    FoqosShieldConfig
    Packages/FoqosShared/Sources
  ].freeze
  FACADE_PATH = 'Packages/FoqosShared/Sources/FoqosShared/Log.swift'
  SITE_BASELINE_PATH = 'scripts/log-privacy-baseline.txt'
  ANNOTATION_BASELINE_PATH = 'scripts/log-privacy-annotation-baseline.txt'
  LOG_LEVELS = %w[debug info warning error].freeze
  VALID_ANNOTATION = %r{^[ \t]*//[ \t]*LOG-PRIVACY-SAFE:[ \t]*\S.*$}

  Finding = Struct.new(:path, :line, :message, keyword_init: true)
  Interpolation = Struct.new(:expression, :line, keyword_init: true)
  Call = Struct.new(
    :path,
    :line,
    :level,
    :source,
    :message_source,
    :message_offset,
    :interpolations,
    keyword_init: true
  )
  Declaration = Struct.new(:name, :type, :origin, keyword_init: true)

  class AnalysisError < StandardError
    attr_reader :path, :line

    def initialize(message, path: nil, line: nil)
      super(message)
      @path = path
      @line = line
    end
  end

  class SwiftLexer
    LEXICAL_TOKEN = %r{//|/\*|\#*"""|\#*"}

    attr_reader :mask, :path, :source

    def initialize(path, source)
      @path = path
      @source = source
      @mask = code_mask
    end

    def log_calls
      calls = []
      token = /(?<![A-Za-z0-9_.])Log\.(#{LOG_LEVELS.join('|')})\b/
      @mask.to_enum(:scan, token).each do
        match = Regexp.last_match
        cursor = skip_space(match.end(0))
        next unless @mask[cursor] == '('

        close_index = balanced_close(cursor, context: 'Log call')
        message_source, message_offset = first_argument(cursor + 1, close_index)
        calls << Call.new(
          path: path,
          line: line_at(match.begin(0)),
          level: match[1],
          source: source[match.begin(0)..close_index],
          message_source: message_source,
          message_offset: message_offset,
          interpolations: interpolations(message_source, message_offset)
        )
      end
      calls
    end

    def direct_sink_findings(relative_path)
      findings = []
      {
        /(?<![A-Za-z0-9_])Logger\s*\(/ => 'Logger',
        /(?<![A-Za-z0-9_])NSLog\s*\(/ => 'NSLog',
        /(?<![A-Za-z0-9_])os_log\s*\(/ => 'os_log'
      }.each do |pattern, sink|
        @mask.to_enum(:scan, pattern).each do
          index = Regexp.last_match.begin(0)
          next if sink == 'os_log' && relative_path == FACADE_PATH

          findings << Finding.new(
            path: path,
            line: line_at(index),
            message: "#{sink} is a direct sink; use the shared Log facade"
          )
        end
      end
      findings
    end

    def annotation_count
      source.lines.count { |line| VALID_ANNOTATION.match?(line) }
    end

    def annotated?(call)
      lines = source.lines
      previous = call.line - 2
      previous >= 0 && VALID_ANNOTATION.match?(lines.fetch(previous, ''))
    end

    private

    def line_at(index)
      source[0...index].count("\n") + 1
    end

    def skip_space(index)
      index += 1 while index < @mask.length && @mask[index]&.match?(/\s/)
      index
    end

    def code_mask
      mask = source.dup
      index = 0
      while (token = LEXICAL_TOKEN.match(source, index))
        index = token.begin(0)
        finish =
          if token[0] == '//'
            source.index("\n", index) || source.length
          elsif token[0] == '/*'
            block_comment_end(index)
          else
            string_end(index)
          end
        blank(mask, index, finish)
        index = finish
      end
      mask
    end

    def blank(mask, start_index, end_index)
      segment = source[start_index...end_index]
      mask[start_index...end_index] = segment.gsub(/[^\n]/, ' ')
    end

    def block_comment_end(start_index)
      depth = 1
      index = start_index + 2
      while index < source.length
        if starts_at?(source, '/*', index)
          depth += 1
          index += 2
        elsif starts_at?(source, '*/', index)
          depth -= 1
          return index + 2 if depth.zero?

          index += 2
        else
          index += 1
        end
      end
      raise AnalysisError.new('unterminated block comment', path: path, line: line_at(start_index))
    end

    def string_start(index)
      return [0, starts_at?(source, '"""', index) ? 3 : 1] if source[index] == '"'
      return unless source[index] == '#'

      cursor = index
      cursor += 1 while source[cursor] == '#'
      return unless source[cursor] == '"'

      hashes = cursor - index
      [hashes, starts_at?(source, '"""', cursor) ? 3 : 1]
    end

    def string_end(start_index)
      hashes, quote_count = string_start(start_index)
      quote_index = start_index + hashes
      cursor = quote_index + quote_count
      closing = ('"' * quote_count) + ('#' * hashes)
      interpolation_open = "\\#{'#' * hashes}("
      while cursor < source.length
        return cursor + closing.length if starts_at?(source, closing, cursor)

        if starts_at?(source, interpolation_open, cursor)
          open_index = cursor + interpolation_open.length - 1
          cursor = balanced_close(open_index, context: 'interpolation') + 1
        else
          cursor += if hashes.zero? && quote_count == 1 && source[cursor] == '\\'
                      2
                    else
                      1
                    end
        end
      end
      raise AnalysisError.new('unterminated Swift string', path: path, line: line_at(start_index))
    end

    def balanced_close(open_index, context:)
      depth = 1
      index = open_index + 1
      while index < source.length
        if starts_at?(source, '//', index)
          index = source.index("\n", index) || source.length
        elsif starts_at?(source, '/*', index)
          index = block_comment_end(index)
        elsif string_start(index)
          index = string_end(index)
        elsif source[index] == '('
          depth += 1
          index += 1
        elsif source[index] == ')'
          depth -= 1
          return index if depth.zero?

          index += 1
        else
          index += 1
        end
      end
      raise AnalysisError.new(
        "unbalanced #{context}",
        path: path,
        line: line_at(open_index)
      )
    end

    def first_argument(start_index, call_close)
      parentheses = 0
      brackets = 0
      braces = 0
      index = start_index
      while index < call_close
        if starts_at?(source, '//', index)
          index = source.index("\n", index) || call_close
        elsif starts_at?(source, '/*', index)
          index = block_comment_end(index)
        elsif string_start(index)
          index = string_end(index)
        else
          case source[index]
          when '(' then parentheses += 1
          when ')' then parentheses -= 1
          when '[' then brackets += 1
          when ']' then brackets -= 1
          when '{' then braces += 1
          when '}' then braces -= 1
          when ','
            return [source[start_index...index], start_index] if parentheses.zero? && brackets.zero? && braces.zero?
          end
          index += 1
        end
      end
      [source[start_index...call_close], start_index]
    end

    def interpolations(message, absolute_offset)
      results = []
      index = 0
      while index < message.length
        start = local_string_start(message, index)
        unless start
          index += 1
          next
        end

        hashes, quote_count = start
        cursor = index + hashes + quote_count
        closing = ('"' * quote_count) + ('#' * hashes)
        interpolation_open = "\\#{'#' * hashes}("
        while cursor < message.length
          break if starts_at?(message, closing, cursor)

          if starts_at?(message, interpolation_open, cursor)
            open_index = cursor + interpolation_open.length - 1
            close_index = local_balanced_close(message, open_index, absolute_offset)
            results << Interpolation.new(
              expression: message[(open_index + 1)...close_index],
              line: line_at(absolute_offset + cursor)
            )
            cursor = close_index + 1
          elsif hashes.zero? && quote_count == 1 && message[cursor] == '\\'
            cursor += 2
          else
            cursor += 1
          end
        end
        if cursor >= message.length
          raise AnalysisError.new(
            'unterminated Swift string in log message',
            path: path,
            line: line_at(absolute_offset + index)
          )
        end

        index = cursor + closing.length
      end
      results
    end

    def local_string_start(text, index)
      return [0, starts_at?(text, '"""', index) ? 3 : 1] if text[index] == '"'
      return unless text[index] == '#'

      cursor = index
      cursor += 1 while text[cursor] == '#'
      return unless text[cursor] == '"'

      [cursor - index, starts_at?(text, '"""', cursor) ? 3 : 1]
    end

    def local_balanced_close(text, open_index, absolute_offset)
      depth = 1
      index = open_index + 1
      while index < text.length
        if (start = local_string_start(text, index))
          hashes, quotes = start
          closing = ('"' * quotes) + ('#' * hashes)
          index += hashes + quotes
          index += 1 until index >= text.length || starts_at?(text, closing, index)
          if index >= text.length
            raise AnalysisError.new(
              'unterminated string in interpolation',
              path: path,
              line: line_at(absolute_offset + open_index)
            )
          end
          index += closing.length
        elsif text[index] == '('
          depth += 1
          index += 1
        elsif text[index] == ')'
          depth -= 1
          return index if depth.zero?

          index += 1
        else
          index += 1
        end
      end
      raise AnalysisError.new(
        'unbalanced interpolation',
        path: path,
        line: line_at(absolute_offset + open_index)
      )
    end

    def starts_at?(text, prefix, index)
      text[index, prefix.length] == prefix
    end
  end

  class Analyzer
    SAFE_PATTERNS = [
      /\.redactedLogLabel\b/,
      /\bShareParticipantLog\.(?:label|statusMessage)\s*\(/,
      /\bDebugRedaction\.\w*ForLog\s*\(/,
      /\bredactedURLString\b/,
      /\bredactedTagIdentifier\b/,
      /\bredactedErrorForLog\s*\(/,
      /\.localizedDescription\b/,
      /\.role(?:\.|$)/,
      /\.count\b/,
      /
        \b(?:
          recordName|zoneName|recordID|zoneID|uuid|UUID|uuidString|sequenceNumber|timestamp|
          startTime|endTime|date|duration|errno
        )\b
      /ix,
      /\b(?:code|status|rawValue)\b/
    ].freeze
    SENSITIVE_TYPE_RULES = [
      [
        /(?:^|\W)(?:any\s+)?Error\b|NSError\b/,
        'whole Error interpolation is prohibited; use redactedErrorForLog(error)'
      ],
      [
        /\b(?:FamilyMember|CKShare\.Participant|CKUserIdentity)\b/,
        'whole object interpolation may expose participant data'
      ],
      [/\b(?:URL|NSURL)\b/, 'raw URL interpolation is prohibited; use redactedURLString'],
      [
        /\b(?:CLLocationCoordinate2D|CLLocation)\b/,
        'raw coordinate interpolation is prohibited'
      ]
    ].freeze
    SENSITIVE_CONTEXT_RULES = [
      [/\b(?:nfc|tag)\b/i, 'replayable NFC identifier interpolation is prohibited'],
      [/\bqr\b|\bscann(?:ed|ing)?\s+code\b/i, 'replayable QR identifier interpolation is prohibited']
    ].freeze
    SAFE_SCALAR_TYPE = /
      \A(?:
        Bool|Int(?:8|16|32|64)?|UInt(?:8|16|32|64)?|Double|Float|CGFloat|
        TimeInterval|Date|UUID|CKRecord\.RecordType
      )\??\z
    /x
    SAFE_DISPLAY_NAME_TYPE = /\A(?:AppMode|FamilyRole|GeofenceRuleType)\z/

    attr_reader :root

    def initialize(root)
      @root = root
    end

    def analyze
      site_floor = read_nonnegative_integer(root.join(SITE_BASELINE_PATH), 'site baseline')
      annotation_baseline = read_nonnegative_integer(
        root.join(ANNOTATION_BASELINE_PATH),
        'annotation baseline'
      )
      files = production_files
      findings = []
      errors = []
      analyzed = 0
      sites = 0
      annotations = 0

      files.each do |file|
        relative_path = file.relative_path_from(root).to_s
        begin
          source = file.read
          lexer = SwiftLexer.new(file, source)
          calls = lexer.log_calls
          sites += calls.length
          annotations += lexer.annotation_count
          findings.concat(lexer.direct_sink_findings(relative_path))
          calls.each do |call|
            analyze_message!(call, lexer)
            findings.concat(analyze_interpolations(call, lexer))
          end
          analyzed += 1
        rescue AnalysisError, Errno::EACCES, Errno::ENOENT => e
          line = e.respond_to?(:line) ? e.line : nil
          errors << Finding.new(
            path: file,
            line: line || 1,
            message: e.message
          )
        end
      end

      if analyzed != files.length
        errors << Finding.new(
          path: root,
          line: 1,
          message: "files_analyzed=#{analyzed} files_discovered=#{files.length}; " \
                   'numeric baselines cannot repair file coverage'
        )
      end
      if annotations != annotation_baseline
        errors << Finding.new(
          path: root.join(ANNOTATION_BASELINE_PATH),
          line: 1,
          message: "annotation count changed from #{annotation_baseline} to #{annotations}"
        )
      end
      if sites < site_floor
        errors << Finding.new(
          path: root.join(SITE_BASELINE_PATH),
          line: 1,
          message: "coverage shrank from #{site_floor} to #{sites} — if you deliberately removed " \
                   'log calls, lower the baseline; if you did not, the analyzer is missing sites'
        )
      end

      totals = "files_discovered=#{files.length} files_analyzed=#{analyzed} " \
               "sites_analyzed=#{sites} annotations=#{annotations}"
      return emit(errors, totals, 2) unless errors.empty?
      return emit(findings, totals, 1) unless findings.empty?

      puts "Log privacy lint passed: #{totals}"
      0
    rescue AnalysisError, OptionParser::ParseError => e
      emit(
        [Finding.new(path: e.respond_to?(:path) ? e.path : root, line: 1, message: e.message)],
        nil,
        2
      )
    end

    private

    def production_files
      PRODUCTION_ROOTS.flat_map do |relative|
        directory = root.join(relative)
        unless directory.directory?
          raise AnalysisError.new("missing production root: #{relative}", path: directory, line: 1)
        end

        directory.glob('**/*.swift').select(&:file?)
      end.sort_by(&:to_s)
    end

    def read_nonnegative_integer(path, label)
      value = path.read
      return Integer(value, 10) if value.match?(/\A\d+\n?\z/)

      raise AnalysisError.new("malformed #{label}: #{path}", path: path, line: 1)
    rescue Errno::ENOENT, Errno::EACCES
      raise AnalysisError.new("malformed #{label}: cannot read #{path}", path: path, line: 1)
    end

    def analyze_message!(call, _lexer)
      message = call.message_source.strip
      return if whole_message_formatter?(message)
      return if literal_message?(message)

      raise AnalysisError.new(
        'message must be an analyzable literal or approved formatter',
        path: call.path,
        line: call.line
      )
    end

    def whole_message_formatter?(message)
      message.match?(/\AShareParticipantLog\.statusMessage\s*\(/m)
    end

    def literal_message?(message)
      remainder = message.dup
      index = 0
      found = false
      while index < message.length
        start = literal_start(message, index)
        unless start
          index += 1
          next
        end

        found = true
        finish = literal_end(message, index, start)
        remainder[index...finish] = ' ' * (finish - index)
        index = finish
      end
      return false unless found

      operands = remainder.split('+').map(&:strip).reject(&:empty?)
      operands.empty? || operands.all? { |operand| safe_expression?(operand) }
    rescue AnalysisError
      false
    end

    def literal_start(text, index)
      return [0, starts_at?(text, '"""', index) ? 3 : 1] if text[index] == '"'
      return unless text[index] == '#'

      cursor = index
      cursor += 1 while text[cursor] == '#'
      return unless text[cursor] == '"'

      [cursor - index, starts_at?(text, '"""', cursor) ? 3 : 1]
    end

    def literal_end(text, index, start)
      hashes, quotes = start
      closing = ('"' * quotes) + ('#' * hashes)
      interpolation_open = "\\#{'#' * hashes}("
      cursor = index + hashes + quotes
      while cursor < text.length
        return cursor + closing.length if starts_at?(text, closing, cursor)

        if starts_at?(text, interpolation_open, cursor)
          open_index = cursor + interpolation_open.length - 1
          cursor = expression_close(text, open_index) + 1
        else
          cursor += hashes.zero? && quotes == 1 && text[cursor] == '\\' ? 2 : 1
        end
      end
      raise AnalysisError, 'unterminated literal'
    end

    def expression_close(text, open_index)
      depth = 1
      cursor = open_index + 1
      while cursor < text.length
        if (start = literal_start(text, cursor))
          cursor = literal_end(text, cursor, start)
        elsif text[cursor] == '('
          depth += 1
          cursor += 1
        elsif text[cursor] == ')'
          depth -= 1
          return cursor if depth.zero?

          cursor += 1
        else
          cursor += 1
        end
      end
      raise AnalysisError, 'unbalanced interpolation'
    end

    def analyze_interpolations(call, lexer)
      declarations = nil
      call.interpolations.filter_map do |interpolation|
        expression = interpolation.expression.strip
        next if safe_expression?(expression)

        if sensitive_display_name?(expression)
          declarations ||= declarations_before(call, lexer)
          next if safe_presentation_display_name?(expression, declarations)
        end

        message = violation_message(expression)
        if message
          Finding.new(path: call.path, line: interpolation.line, message: message)
        elsif (identifier = semantic_identifier(expression))
          analyze_semantic_origin(identifier, call, interpolation, lexer)
        end
      end
    end

    def starts_at?(text, prefix, index)
      text[index, prefix.length] == prefix
    end

    def safe_expression?(expression)
      SAFE_PATTERNS.any? { |pattern| pattern.match?(expression) }
    end

    def violation_message(expression)
      return 'whole Error interpolation is prohibited; use redactedErrorForLog(error)' if bare_error?(expression)
      return 'whole object interpolation may expose participant data' if whole_object?(expression)
      return 'sensitive display name interpolation' if sensitive_display_name?(expression)
      return 'participant contact interpolation exposes name/email/phone data' if participant_contact?(expression)
      return 'raw coordinate interpolation is prohibited' if expression.match?(/\b(?:coordinate|latitude|longitude)\b/i)
      if expression.match?(/\b(?:url|absoluteString|query)\b/i)
        return 'raw URL interpolation is prohibited; use redactedURLString'
      end
      if expression.match?(/\b(?:nfc|tag)\w*(?:id|identifier)|\btagIdentifier\b/i)
        return 'replayable NFC identifier interpolation is prohibited'
      end
      return unless expression.match?(/\bqr(?:code|value|id|identifier)\b|\bscannedCode\b/i)

      'replayable QR identifier interpolation is prohibited'
    end

    def bare_error?(expression)
      expression.match?(/\A(?:error|[A-Za-z_][A-Za-z0-9_]*(?:error|Error))\z/) ||
        expression.match?(/\AString\s*\(\s*describing:\s*[^)]*(?:error|Error)\s*\)\z/)
    end

    def whole_object?(expression)
      expression.match?(/\A(?:member|participant|person|userIdentity)\z/i) ||
        expression.match?(/\AString\s*\(\s*describing:\s*(?:member|participant|person|userIdentity)\s*\)\z/i)
    end

    def sensitive_display_name?(expression)
      expression.match?(/\.displayName\b/) &&
        !expression.match?(/\.(?:role|mode|ruleType)\.displayName\b/)
    end

    def safe_presentation_display_name?(expression, declarations)
      receiver = expression.match(/\A([A-Za-z_][A-Za-z0-9_]*)\.displayName\z/)&.[](1)
      receiver && declarations[receiver]&.type&.match?(SAFE_DISPLAY_NAME_TYPE)
    end

    def participant_contact?(expression)
      expression.match?(/\b(?:nameComponents|emailAddress|phoneNumber)\b/)
    end

    def simple_identifier?(expression)
      expression.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    def semantic_identifier(expression)
      return expression if simple_identifier?(expression)

      match = expression.match(
        /\AString\s*\(\s*describing:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\z/
      )
      match&.[](1)
    end

    def analyze_semantic_origin(identifier, call, interpolation, lexer)
      return if lexer.annotated?(call)

      declarations = declarations_before(call, lexer)
      context = message_context(call)
      classification, message = classify_identifier(identifier, declarations, context)
      if classification == :sensitive
        return Finding.new(
          path: call.path,
          line: interpolation.line,
          message: message
        )
      end
      return if classification == :safe

      raise AnalysisError.new(
        "cannot resolve suspicious origin for #{identifier}; add an adjacent " \
        '// LOG-PRIVACY-SAFE: reason only after audit',
        path: call.path,
        line: interpolation.line
      )
    end

    def declarations_before(call, lexer)
      source_before_call = lexer.source[0...call.message_offset]
      mask_before_call = lexer.mask[0...call.message_offset]
      function_start = source_before_call.rindex(/\b(?:func|init)\b/) || 0
      source_scope = source_before_call[function_start..]
      mask_scope = mask_before_call[function_start..]
      declarations = parameter_declarations(source_scope, mask_scope)

      assignment_pattern =
        /^[ \t]*(?:(?:guard|if)\s+)?(?:case\s+)?(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^=\n]+))?\s*=/
      mask_scope.to_enum(:scan, assignment_pattern).each do
        assignment = Regexp.last_match
        origin = assignment_origin(source_scope, mask_scope, assignment)
        declarations[assignment[1]] = Declaration.new(
          name: assignment[1],
          type: assignment[2]&.strip,
          origin: origin
        )
      end
      declarations
    end

    def parameter_declarations(source_scope, mask_scope)
      brace_index = mask_scope.index('{')
      return {} unless brace_index

      signature = source_scope[0...brace_index]
      declarations = {}
      signature.to_enum(
        :scan,
        /(?:\A|[,(])\s*(?:(?:_|[A-Za-z_][A-Za-z0-9_]*)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^,)=]+)/
      ).each do
        parameter = Regexp.last_match
        declarations[parameter[1]] = Declaration.new(
          name: parameter[1],
          type: parameter[2].strip,
          origin: nil
        )
      end
      declarations
    end

    def assignment_origin(source_scope, mask_scope, assignment)
      control_binding = assignment[0].lstrip.start_with?('if ', 'guard ')
      origin_end = assignment_origin_end(
        mask_scope,
        assignment.end(0),
        control_binding: control_binding
      )
      source_scope[assignment.end(0)...origin_end].strip
    end

    def assignment_origin_end(mask_scope, origin_start, control_binding:)
      index = origin_start
      depth = 0
      has_code = false
      while index < mask_scope.length
        character = mask_scope[index]
        case character
        when '(', '[' then depth += 1
        when '{'
          return index if control_binding && depth.zero?

          depth += 1
        when ')', ']', '}' then depth -= 1 if depth.positive?
        when ';' then return index if depth.zero?
        when "\n"
          return index if has_code && depth.zero? && !assignment_continues?(mask_scope, origin_start, index)
        end
        has_code ||= !character.match?(/\s/)
        index += 1
      end
      index
    end

    def assignment_continues?(mask_scope, origin_start, newline_index)
      previous_line = mask_scope[origin_start...newline_index].rstrip.lines.last.to_s
      next_content = mask_scope.index(/\S/, newline_index + 1)
      return false unless next_content

      next_line_end = mask_scope.index("\n", next_content) || mask_scope.length
      next_line = mask_scope[next_content...next_line_end].lstrip
      previous_line.match?(%r{(?:\?\?|&&|\|\||->|[=,+\-*/%&|?:.])\z}) ||
        next_line.match?(%r{\A(?:\?\?|&&|\|\||[.,+\-*/%&|?:])})
    end

    def classify_identifier(identifier, declarations, context, visiting = Set.new)
      declaration = declarations[identifier]
      return [:ambiguous, nil] unless declaration
      return [:ambiguous, nil] if visiting.include?(identifier)
      if (context_result = context_classification(context))
        return context_result
      end

      if (message = sensitive_type_message(declaration.type))
        return [:sensitive, message]
      end

      return safe_scalar_classification(declaration.type) if declaration.origin.nil?

      origin = declaration.origin
      sensitive_origin =
        violation_message(origin) || participant_contact?(origin) || sensitive_display_name?(origin)
      if sensitive_origin && !safe_presentation_display_name?(origin, declarations)
        return [:sensitive, "sensitive local origin for #{identifier}"]
      end
      return [:safe, nil] if safe_expression?(origin)

      dependencies = origin.scan(/\b[A-Za-z_][A-Za-z0-9_]*\b/).uniq & declarations.keys
      next_visiting = visiting.dup.add(identifier)
      dependency_results = dependencies.map do |dependency|
        classify_identifier(dependency, declarations, context, next_visiting)
      end
      if dependency_results.any? { |classification, _| classification == :sensitive }
        return [:sensitive, "sensitive local origin for #{identifier}"]
      end
      return [:ambiguous, nil] if dependency_results.any? { |classification, _| classification == :ambiguous }
      return [:safe, nil] unless dependencies.empty?

      literal_origin_classification(origin) || safe_scalar_classification(declaration.type)
    end

    def sensitive_type_message(type)
      return unless type

      SENSITIVE_TYPE_RULES.each do |pattern, message|
        return message if pattern.match?(type)
      end
      nil
    end

    def context_classification(context)
      SENSITIVE_CONTEXT_RULES.each do |pattern, message|
        return [:sensitive, message] if pattern.match?(context)
      end
      nil
    end

    def safe_scalar_classification(type)
      return [:safe, nil] if type&.match?(SAFE_SCALAR_TYPE)

      [:ambiguous, nil]
    end

    def literal_origin_classification(origin)
      return [:safe, nil] if origin.match?(/\A(?:true|false|nil|-?\d+(?:\.\d+)?|"(?:[^"\\]|\\.)*")\z/m)

      nil
    end

    def message_context(call)
      context = call.message_source.dup
      call.interpolations.each { |interpolation| context.sub!(interpolation.expression, '') }
      context
    end

    def emit(items, totals, status)
      items.each do |item|
        location = item.path || root
        warn "#{location}:#{item.line || 1}: error: #{item.message}"
      end
      warn "Log privacy lint totals: #{totals}" if totals
      status
    end
  end

  def self.run(argv)
    root = nil
    parser = OptionParser.new do |options|
      options.banner = 'Usage: check-log-privacy.rb --root PATH'
      options.on('--root PATH') { |value| root = Pathname(value).expand_path }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--root' unless root
    raise OptionParser::InvalidArgument, "root is not a directory: #{root}" unless root.directory?
    raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

    Analyzer.new(root).analyze
  rescue OptionParser::ParseError => e
    warn "check-log-privacy.rb:1: error: #{e.message}"
    2
  end
end

exit LogPrivacy.run(ARGV) if $PROGRAM_NAME == __FILE__
