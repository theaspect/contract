class CustomPDFConverter < (Asciidoctor::Converter.for 'pdf')
    register_for 'pdf'
  
    def init_pdf doc
      @parents = []
      super
    end

    def convert_olist node
      add_dest_for_block node if node.id
      # TODO: move list_numeral resolve to a method
      # case node.style
      # when 'arabic'
      #   list_numeral = 1
      # when 'decimal'
      #   list_numeral = '01'
      # when 'loweralpha'
      #   list_numeral = 'a'
      # when 'upperalpha'
      #   list_numeral = 'A'
      # when 'lowerroman'
      #   list_numeral = RomanNumeral.new 'i'
      # when 'upperroman'
      #   list_numeral = RomanNumeral.new 'I'
      # when 'lowergreek'
      #   list_numeral = LowercaseGreekA
      # when 'unstyled', 'unnumbered', 'no-bullet'
      #   list_numeral = nil
      # when 'none'
      #   list_numeral = ''
      # else
      #   list_numeral = 1
      # end
      # Override ordering schema
      list_numeral = 1
      if list_numeral && list_numeral != '' &&
        (start = (node.attr 'start', nil, false) || ((node.option? 'reversed') ? node.items.size : nil))
        if (start = start.to_i) > 1
          (start - 1).times { list_numeral = list_numeral.next }
        elsif start < 1 && !(::String === list_numeral)
          (start - 1).abs.times { list_numeral = list_numeral.pred }
        end
      end
      @list_numerals << list_numeral
      convert_outline_list node
      @list_numerals.pop
    end

    def convert_outline_list node
      # TODO: check if we're within one line of the bottom of the page
      # and advance to the next page if so (similar to logic for section titles)
      layout_caption node.title, category: :outline_list if node.title?

      opts = {}
      if (align = resolve_alignment_from_role node.roles)
        opts[:align] = align
      elsif node.style == 'bibliography'
        opts[:align] = :left
      elsif (align = @theme.outline_list_text_align)
        # NOTE: theme setting only affects alignment of list text (not nested blocks)
        opts[:align] = align.to_sym
      end

      line_metrics = calc_line_metrics @theme.base_line_height
      complex = false
      # ...or if we want to give all items in the list the same treatment
      #complex = node.items.find(&:complex?) ? true : false
      if (node.context == :ulist && !@list_bullets[-1]) || (node.context == :olist && !@list_numerals[-1])
        if node.style == 'unstyled'
          # unstyled takes away all indentation
          list_indent = 0
        elsif (list_indent = @theme.outline_list_indent || 0) > 0
          # no-bullet aligns text with left-hand side of bullet position (as though there's no bullet)
          list_indent = [list_indent - (rendered_width_of_string %(#{node.context == :ulist ? ?\u2022 : '1.'}x)), 0].max
        end
      else
        list_indent = @theme.outline_list_indent || 0
      end
      indent list_indent do
        node.items.each do |item|
          allocate_space_for_list_item line_metrics
          convert_outline_list_item item, node, opts
        end
      end
      # NOTE: Children will provide the necessary bottom margin if last item is complex.
      # However, don't leave gap at the bottom if list is nested in an outline list
      unless complex || (node.nested? && node.parent.parent.outline?)
        # correct bottom margin of last item
        margin_bottom((@theme.prose_margin_bottom || 0) - (@theme.outline_list_item_spacing || 0))
      end
    end

    def convert_outline_list_item node, list, opts = {}
      # TODO: move this to a draw_bullet (or draw_marker) method
      marker_style = {}
      marker_style[:font_color] = @theme.outline_list_marker_font_color || @font_color
      marker_style[:font_family] = font_family
      marker_style[:font_size] = font_size
      marker_style[:line_height] = @theme.base_line_height
      case (list_type = list.context)
      when :ulist
        complex = node.complex?
        if (marker_type = @list_bullets[-1])
          if marker_type == :checkbox
            # QUESTION should we remove marker indent if not a checkbox?
            if node.attr? 'checkbox', nil, false
              marker_type = (node.attr? 'checked', nil, false) ? :checked : :unchecked
              marker = @theme[%(ulist_marker_#{marker_type}_content)] || BallotBox[marker_type]
            end
          else
            marker = @theme[%(ulist_marker_#{marker_type}_content)] || Bullets[marker_type]
          end
          [:font_color, :font_family, :font_size, :line_height].each do |prop|
            marker_style[prop] = @theme[%(ulist_marker_#{marker_type}_#{prop})] || @theme[%(ulist_marker_#{prop})] || marker_style[prop]
          end if marker
        end
      when :olist
        complex = node.complex?
        if (index = @list_numerals.pop)
          if index == ''
            marker = ''
          else
            marker = %(#{index}.)
            @parents << marker
            marker = @parents.join("")
            dir = (node.parent.option? 'reversed') ? :pred : :next
            @list_numerals << (index.public_send dir)
          end
        end
      when :dlist
        # NOTE: list.style is 'qanda'
        complex = node[1]&.complex?
        @list_numerals << (index = @list_numerals.pop).next
        marker = %(#{index}.)
      else
        complex = node.complex?
        logger.warn %(unknown list type #{list_type.inspect}) unless scratch?
        marker = @theme.ulist_marker_disc_content || Bullets[:disc]
      end

      if marker
        if marker_style[:font_family] == 'fa'
          logger.info 'deprecated fa icon set found in theme; use fas, far, or fab instead' unless scratch?
          marker_style[:font_family] = FontAwesomeIconSets.find {|candidate| (icon_font_data candidate).yaml[candidate].value? marker } || 'fas'
        end
        marker_gap = rendered_width_of_char 'x'
        font marker_style[:font_family], size: marker_style[:font_size] do
          marker_width = rendered_width_of_string marker
          # NOTE compensate if character_spacing is not applied to first character
          # see https://github.com/prawnpdf/prawn/commit/c61c5d48841910aa11b9e3d6f0e01b68ce435329
          character_spacing_correction = 0
          character_spacing(-0.5) do
            character_spacing_correction = 0.5 if (rendered_width_of_char 'x', character_spacing: -0.5) == marker_gap
          end
          marker_height = height_of_typeset_text marker, line_height: marker_style[:line_height], single_line: true
          start_position = -marker_width + -marker_gap + character_spacing_correction
          float do
            start_new_page if @media == 'prepress' && cursor < marker_height
            flow_bounding_box start_position, width: marker_width do
              layout_prose marker,
                           align: :right,
                           character_spacing: -0.5,
                           color: marker_style[:font_color],
                           inline_format: false,
                           line_height: marker_style[:line_height],
                           margin: 0,
                           normalize: false,
                           single_line: true
            end
          end
        end
      end

      if complex
        traverse_list_item node, list_type, (opts.merge normalize_line_height: true)
      else
        traverse_list_item node, list_type, (opts.merge margin_bottom: @theme.outline_list_item_spacing, normalize_line_height: true)
      end

      @parents.pop
    end
end
