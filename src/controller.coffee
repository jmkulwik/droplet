# ICE Editor Controller
#
# Copyright (c) 2014 Anthony Bau.
#
# MIT License

INDENT_SPACES = 2
INPUT_LINE_HEIGHT = 15
PALETTE_MARGIN = 10
PALETTE_WIDTH = 300
MIN_DRAG_DISTANCE = 5

exports.IceEditorChangeEvent = class IceEditorChangeEvent
  constructor: (@block, @target) ->

# #The Editor class
# This class contains all the controller functions for ICE Editor.
# Call:
#   new Editor(DOMElement, palette)
# to initialize an ICE editor in an element.

exports.Editor = class Editor
  constructor: (el, @paletteBlocks) ->

    # ## Field declaration ##
    # (useful to have all in one place)
    
    # If we did not recieve palette blocks in the constructor, we have no palette.
    @paletteBlocks ?= []
    
    # We discard the blocks we are fed, preferring to clone them
    # to be as unintrusive as possible (also to get blocks unattached to any
    # token stream)
    @paletteBlocks = (paletteBlock.clone() for paletteBlock in @paletteBlocks)

    # MODEL instances (program state)
    @tree = null # The root tree
    @floatingBlocks = [] # The other root blocks that are not attached to the root tree
    
    # TEXT INPUT interactive fields
    @focus = null # The focused empty socket, if such thing exists.
    @editedText = null # The focused textToken, if such thing exists (associated with @focus).
    @handwritten = false # Are we editing a handwritten line?
    @hiddenInput = null

    @isEditingText = => @hiddenInput is document.activeElement

    textInputAnchor = textInputHead = null # The selection anchor and head in the input

    textInputSelecting = false

    _editedInputLine = -1

    # NORMAL DRAG interactive fields
    @selection = null # The currently-dragged set of blocks

    # LASSO SELECT interactive fields
    @lassoSegment = null
    @_lassoBounds = null

    # CURSOR interactive fields
    @cursor = new CursorToken()

    # UNDO STACK
    @undoStack = []

    # Scroll offset
    @scrollOffset = new draw.Point 0, 0

    offset = null
    highlight = null
    
    # ## DOM SETUP ##

    # The main canvas
    main = document.createElement 'canvas'; main.className = 'canvas'
    main.height = el.offsetHeight
    main.width = el.offsetWidth - PALETTE_WIDTH

    # The palette canvas
    palette = document.createElement 'canvas'; palette.className = 'palette'
    palette.height = el.offsetHeight
    palette.width = PALETTE_WIDTH

    # The drag canvas
    drag = document.createElement 'canvas'; drag.className = 'drag'
    drag.height = el.offsetHeight
    drag.width = el.offsetWidth - PALETTE_WIDTH

    # The hidden input
    @hiddenInput = document.createElement 'input'; @hiddenInput.className = 'hidden_input'

    # The mouse tracking div
    track = document.createElement 'div'; track.className = 'trackArea'

    # Append the children
    for child in [main, palette, drag, track, @hiddenInput]
      el.appendChild child

    # Get the contexts from each canvas
    mainCtx = main.getContext '2d'
    dragCtx = drag.getContext '2d'
    paletteCtx = palette.getContext '2d'

    # The main context will be used for draw.js's text measurements (this is a bit of a hack)
    draw._setCTX mainCtx

    # ## Convenience Functions ##
    # General-purpose methods that call the view (rendering functions)
    
    @clear = =>
      mainCtx.clearRect @scrollOffset.x, @scrollOffset.y, main.width, main.height
    
    # ## Redraw ##
    # redraw does three main things: redraws the root tree (@tree)
    # redraws any floating blocks (@floatingBlocks), and draws the bounding rectangle
    # of any lassoed segments.
    @redraw = =>
      # Clear the main canvas
      @clear()

      # Compute the root tree
      @tree.view.compute()

      # Draw it on the main context
      @tree.view.draw mainCtx
      
      # Alert the lasso segment, if it exists, to recompute its bounds
      if @lassoSegment?
        # Get those compute bounds
        @_lassoBounds = @lassoSegment.view.getBounds()

        for float in @floatingBlocks
          if @lassoSegment is float.block
            @_lassoBounds.translate float.position
        
        # Unless we're already drawing it on the drag canvas, draw the lasso segment borders on the main canvas
        unless @lassoSegment is @selection
          @_lassoBounds.stroke mainCtx, '#000'
          @_lassoBounds.fill mainCtx, 'rgba(0, 0, 256, 0.3)'

      for float in @floatingBlocks
        view = float.block.view
        
        # Recompute this floating block's coordinates
        view.compute()
        view.translate float.position

        # Draw it on the main context
        view.draw mainCtx

    @attemptReparse = =>
      try
        @tree = (coffee.parse @getValue()).segment
        @redraw()

    moveBlockTo = (block, target) =>
      parent = block.start.prev
      while parent? and (parent.type is 'newline' or (parent.type is 'segmentStart' and parent.segment isnt @tree) or parent.type is 'cursor') then parent = parent.prev

      @undoStack.push
        block: block
        target: if parent? then (switch parent.type
          when 'indentStart', 'indentEnd' then parent.indent
          when 'blockStart', 'blockEnd' then parent.block
          when 'socketStart', 'socketEnd' then parent.socket
          when 'segmentStart', 'segmentEnd' then parent.segment
          else parent) else null

      block.moveTo target
      if @onChange? then @onChange new IceEditorChangeEvent block, target

    @undo = =>
      # If the undo stack is empty, give up.
      unless @undoStack.length > 0 then return

      operation = lastOperation = target: null
      
      until operation.target? or operation.block isnt lastOperation.block
        # Otherwise, pop from the undo stack
        operation = @undoStack.pop()

        unless operation? then break
        
        # Simulate dropping the block into its target
        if operation.target? then switch operation.target.type
          when 'indent'
            head = operation.target.end.prev
            while head.type is 'segmentEnd' or head.type is 'segmentStart' or head.type is 'cursor' then head = head.prev

            if head.type is 'newline'
              # There's already a newline here.
              operation.block.moveTo operation.target.start.next
            else
              # An insert drop signifies that we want to drop the block at the start of the indent
              operation.block.moveTo operation.target.start.insert new NewlineToken()

          when 'block'
            # A block drop signifies that we want to drop the block after (the end of) the block.
            operation.block.moveTo operation.target.end.insert new NewlineToken()

          when 'socket'
            # Remove any previously occupying block or text
            if operation.target.content()? then operation.target.content().remove()

            # Insert
            operation.block.moveTo operation.target.start
          
          else
            if operation.target is @tree
              # We can also drop on the root tree (insert at the start of the program)
              operation.block.moveTo @tree.start

              # Don't insert a newline if it would create an empty line at the end of the file.
              unless operation.block.end.next is @tree.end
                operation.block.end.insert new NewlineToken()
        else
          operation.block.moveTo operation.target

      @redraw()

      if @onChange? then @onChange new IceEditorChangeEvent operation.block, operation.target
    
    # The redrawPalette function ought to be called only once in the current code structure.
    # If we want to scroll the palette later on, then this will be called to do so.
    @redrawPalette = =>
      # We need to keep track of the bottom edge of the last element,
      # so we know where to put the top of the next one (there will be a margin of PALETTE_MARGIN between them)
      lastBottomEdge = 0

      for paletteBlock in @paletteBlocks
        # Compute the coordinates
        paletteBlock.view.compute()

        # Translate it into position
        paletteBlock.view.translate new draw.Point 0, lastBottomEdge

        # Increment the running height count
        lastBottomEdge = paletteBlock.view.bounds[paletteBlock.view.lineEnd].bottom() + PALETTE_MARGIN # Add margin

        # Finish and draw the palette block
        paletteBlock.view.draw paletteCtx
    
    # (call it right away)
    @redrawPalette()
    
    # ##Cursor operations ##
    # Functions that manipulate the cursor. The cursor is a normal ICE editor model token
    # that is rendered specially in the View.

    insertHandwrittenBlock = =>
      # Create the new block and socket for a new handwritten line
      newBlock = new Block []; newSocket = new Socket []
      newSocket.handwritten = true

      # Put the new socket into the new block
      newBlock.start.insert newSocket.start; newBlock.end.prev.insert newSocket.end
      
      # Move it to where the cursor should be
      if @cursor.next.type is 'newline' or @cursor.next.type is 'indentEnd' or @cursor.next.type is 'segmentEnd'
        if @cursor.next.type is 'indentEnd' and @cursor.prev.type is 'newline'
          moveBlockTo newBlock, @cursor.prev
        else
          moveBlockTo newBlock, @cursor.prev.insert new NewlineToken()

        @redraw()
        setTextInputFocus newSocket

      else if @cursor.prev.type is 'newline' or @cursor.prev.type is 'segmentStart'

        moveBlockTo newBlock, @cursor.prev

        newBlock.end.insert new NewlineToken()

        @redraw()
        setTextInputFocus newSocket

      scrollCursorIntoView()

    scrollCursorIntoView = =>
      @redraw()
      
      # If the cursor has scrolled out of view, scroll it back into view.
      if @cursor.view.point.y < @scrollOffset.y
        mainCtx.translate 0, @scrollOffset.y - @cursor.view.point.y
        @scrollOffset.y = @cursor.view.point.y

        @redraw()
      else if @cursor.view.point.y > (@scrollOffset.y + main.height)
        mainCtx.translate 0, (@scrollOffset.y + main.height) - @cursor.view.point.y
        @scrollOffset.y = @cursor.view.point.y - main.height

        @redraw()

    moveCursorTo = (token) =>
      # Splice out
      @cursor.remove()

      # Find the newline or end markup after the given token.
      # Special case: we can also focus the very start of the tree.
      head = token
      unless head is @tree.start
        until (not head?) or head.type in ['newline', 'indentEnd', 'segmentEnd'] then head = head.next

      # If there is no place to put the cursor, give up.
      unless head? then return

      # Splice in
      if head.type is 'newline' or head is @tree.start
        head.insert @cursor
      else
        head.insertBefore @cursor

      scrollCursorIntoView()
    
    moveCursorBefore = (token) =>
      # Splice out
      @cursor.remove()
      
      # Splice in
      token.insertBefore @cursor

      scrollCursorIntoView()

    deleteFromCursor = =>
      # Seek the block that we want to delete (i.e. the block that ends first before the cursor, if such thing exists)
      head = @cursor.prev
      while head isnt null and head.type isnt 'indentStart' and head.type isnt 'blockEnd'
        head = head.prev
      
      # If there is no block before the cursor, give up.
      if head is null then return

      # Delete that block and redraw
      if head.type is 'blockEnd' then moveBlockTo head.block, null; @redraw()

      scrollCursorIntoView()
    
    # TODO the following are known not to be able to navigate to the end of an indent.
    moveCursorUp = =>
      # Seek newline
      head = @cursor.prev.prev
      while head isnt null and not (head.type in ['newline', 'indentEnd', 'segmentStart'])
        head = head.prev
      
      # If head is null, we are at the beginning of the file.
      # So, give up.
      if head is null then return

      if head.type is 'indentEnd'
        moveCursorBefore head
      else
        moveCursorTo head

      # Make sure that we're not inside a block only.
      # This requires finding the immediate parent of the cursor
      head = @cursor; depth = 0
      until head.type in ['blockEnd', 'indentEnd', 'segmentEnd'] and depth is 0
        switch head.type
          when 'blockStart', 'indentStart', 'segmentStart', 'socketStart' then depth += 1
          when 'blockEnd', 'indentEnd', 'segmentEnd', 'socketEnd' then depth -= 1
        head = head.next
      
      # If we're in a bad place, then move us further.
      if head.type is 'blockEnd' then moveCursorUp()

    moveCursorDown = =>
      # Seek newline or newline-like character.
      head = @cursor.next.next
      while head isnt null and not (head.type in ['newline', 'indentEnd', 'segmentEnd'])
        head = head.next

      # If head is null, we are at the end of the file.
      # So, give up.
      if head is null then return

      if head.type is 'indentEnd' or head.type is 'segmentEnd'
        moveCursorBefore head
      else
        moveCursorTo head

      # Make sure that we're not inside a block only.
      # This requires finding the immediate parent of the cursor
      head = @cursor; depth = 0
      until head.type in ['blockEnd', 'indentEnd', 'segmentEnd'] and depth is 0
        switch head.type
          when 'blockStart', 'indentStart', 'segmentStart', 'socketStart' then depth += 1
          when 'blockEnd', 'indentEnd', 'segmentEnd', 'socketEnd' then depth -= 1
        head = head.next
      
      # If we're in a bad place, then move us further.
      if head.type is 'blockEnd' then moveCursorDown()
    
    # ## Hidden Input events ##

    # For normal text input, we use the "input", "keydownhtml event
    for eventName in ['input', 'keydown', 'keyup', 'keypress']
      @hiddenInput.addEventListener eventName, (event) =>
        # If we haven't focused anything, this input does nothing.
        unless @isEditingText() then return true

        redrawTextInput()

    # For keyboard shortcuts, we use the "keydown" html event
    @hiddenInput.addEventListener 'keydown', (event) =>
      # If we're not actually editing an input, this isn't our responsibility,
      # so return immediately.
      unless @isEditingText() then return true

      # Otherwise, see if we want to make a keyboard shortcut.
      switch event.keyCode
        when 13
          if @handwritten then insertHandwrittenBlock()
          else setTextInputFocus null; @hiddenInput.blur(); @redraw()
        when 8 then if @handwritten and @hiddenInput.value.length is 0
          deleteFromCursor(); setTextInputFocus null; @hiddenInput.blur()
        when 9 then if @handwritten
          # Seek the block right before this handwritten block
          head = @focus.start.prev.prev
          head = head.prev while head isnt null and head.type isnt 'blockEnd' and head.type isnt 'blockStart'
          
          # If we have found a wrapping (parent) block, then we can't do an indent, so give up.
          if head.type is 'blockStart' then return

          # Otherwise, see if the last child of this block is an indent
          else if head.prev.type is 'indentEnd'
            # Note that it is guaranteed that a handwritten block satisfies @focus.start.prev.block is (the wrapping block)
            moveBlockTo @focus.start.prev.block, head.prev.prev.insert new NewlineToken() # Move the block we're editing into the indent

            # Move the cursor into its proper position (after this block)
            moveCursorTo @focus.start.prev.block.end

            @redraw()
            event.preventDefault(); return false
          
          # We have found a block we want to move into, but there's no indent here, so create one.
          else
            # Create and insert a new indent
            newIndent = new Indent [], INDENT_SPACES
            head.prev.insert newIndent.start; head.prev.insert newIndent.end

            # Move the block we're editing into this new indent
            moveBlockTo @focus.start.prev.block, newIndent.start.insert new NewlineToken()

            # Move the cursor into its proper position (after this block)
            moveCursorTo @focus.start.prev.block.end

            @redraw()
            event.preventDefault(); return false
        when 38 then setTextInputFocus null; @hiddenInput.blur(); moveCursorUp(); @redraw()
        when 40 then setTextInputFocus null; @hiddenInput.blur(); moveCursorDown(); @redraw()
        when 37 then if @hiddenInput.selectionStart is @hiddenInput.selectionEnd and @hiddenInput.selectionStart is 0
          # Pressing the left-arrow at the leftmost end of a socket brings us to the previous socket
          head = @focus.start
          until not head? or head.type is 'socketEnd' and not (head.socket.content()?.type in ['block', 'socket'])
            head = head.prev
            
          # If we have reached the beginning of the file, give up.
          unless head? then return

          setTextInputFocus head.socket
        when 39 then if @hiddenInput.selectionStart is @hiddenInput.selectionEnd and @hiddenInput.selectionStart is @hiddenInput.value.length
          # Pressing right left-arrow at the rightmost end of a socket brings us to the next socket
          head = @focus.end
          until not head? or head.type is 'socketStart' and not (head.socket.content()?.type in ['block', 'socket'])
            head = head.next
            
          # If we have reached the end of the file, give up.
          unless head? then return

          setTextInputFocus head.socket
    
    # When we blur the hidden input, also blur the canvas text focus
    @hiddenInput.addEventListener 'blur', (event) =>
      # If we have actually blurred (as opposed to simply unfocused the browser window)
      if event.target isnt document.activeElement then setTextInputFocus null
    
    # Bind keyboard shortcut events to the document

    document.body.addEventListener 'keydown', (event) =>
      # Keyboard shortcuts don't apply if they were executed in a text input area
      if event.target.tagName in ['INPUT', 'TEXTAREA'] then return
      
      switch event.keyCode
        when 13 then unless @isEditingText() then insertHandwrittenBlock()
        when 38 then if @cursor? then moveCursorUp()
        when 40 then if @cursor? then moveCursorDown()
        when 8 then if @cursor? then deleteFromCursor()
        when 37 then if @cursor?
          head = @cursor
          
          until not head? or head.type is 'socketEnd' and not (head.socket.content()?.type in ['block', 'socket'])
            head = head.prev
          
          unless head? then return

          setTextInputFocus head.socket
        when 39 then if @cursor?
          # Pressing the left-arrow at the rightmost end of a socket brings us to the next socket
          head = @cursor
          until not head? or head.type is 'socketStart' and not (head.socket.content()?.type in ['block', 'socket'])
            head = head.next
            
          # If we have reached the beginning of the file, give up.
          unless head? then return

          setTextInputFocus head.socket
      
      # If we manipulated the root tree, redraw.
      if event.keyCode in [13, 38, 40, 8] then @redraw()
      
      # If we caught the keypress, prevent default.
      if event.keyCode in [13, 38, 40, 8, 37] then event.preventDefault()

    # Hit-testing functions

    hitTest = (point, root) =>
      head = root; seek = null
      while head isnt seek
        if head.type is 'blockStart' and head.block.view.path.contains point
          seek = head.block.end
        head = head.next
      
      if seek? then seek.block else null

    hitTestRoot = (point) => hitTest point, @tree.start
    
    hitTestFloating = (point) =>
      for float in @floatingBlocks
        if hitTest(point, float.block.start) isnt null then return float.block
      return null
    
    hitTestFocus = (point) =>
      head = @tree.start
      while head isnt null
        if head.type is 'socketStart' and
            (head.next.type is 'text' or head.next.type is 'socketEnd') and
            head.socket.view.bounds[head.socket.view.lineStart].contains point
          return head.socket
        head = head.next

      return null
    
    hitTestLasso = (point) => if @lassoSegment? and @_lassoBounds.contains point then @lassoSegment else null

    hitTestPalette = (point) =>
      point = new draw.Point point.x + PALETTE_WIDTH, point.y
      for block in @paletteBlocks
        if hitTest(point, block.start)? then return block
      return null

    # ## The mousedown event ##
    
    # ### getPointFromEvent ###
    # This is a conveneince function, which will contain compatability layers for getting
    # the offset coordinates of a mouse click point

    getPointFromEvent = (event) =>
      switch
        when event.offsetX? then new draw.Point event.offsetX - PALETTE_WIDTH, event.offsetY + @scrollOffset.y
        when event.layerX then new draw.Point event.layerX - PALETTE_WIDTH, event.layerY + @scrollOffset.y
    
    track.addEventListener 'mousedown', (event) =>
      # Only capture left-click
      unless event.button is 0 then return
      
      # Forcefully blur the hidden input if it is focused, removing
      # the focus from any sockets
      @hiddenInput.blur()

      point = getPointFromEvent event

      # See what we picked up
      @ephemeralSelection = hitTestFloating(point) ?
        hitTestLasso(point) ?
        hitTestFocus(point) ?
        hitTestRoot(point) ?
        hitTestPalette(point)
      
      if not @ephemeralSelection?
        # If we haven't clicked on any clickable element, then LASSO SELECT, indicated by (@lassoAnchor?)
        
        # If there is already a selection, remove it.
        if @lassoSegment?

          # First, check to see if the block is floating
          flag = false
          for float in @floatingBlocks
            if float.block is @lassoSegment
              flag = true
              break

          unless flag # Don't remove the segment if it's floating, because it still needs to hold those blocks together
            @lassoSegment.remove()

          @lassoSegment = null
          @redraw()

        # Set the lasso anchor
        @lassoAnchor = point

      else if @ephemeralSelection.type is 'socket'
        # If we have clicked on a socket, then TEXT INPUT, indicated by (@isEditingText())
        
        # Set the text input up for editing
        setTextInputFocus @ephemeralSelection
        
        # Don't actually drag anything
        @ephemeralSelection = null

        # We must set a timeout for the following, because until
        # A render has passed, the hidden input is not actually focused.
        setTimeout (=>
          setTextInputAnchor point
          redrawTextInput()
          
          # While the mouse is down, we are trying to select text in the input
          textInputSelecting = true), 0

      else
        # If we have clicked on a block or segment, then NORMAL DRAG, indicated by (@ephemeralSelection?)

        # A flag as to whether we are selecting something in the palette
        selectionInPalette = false

        @ephemeralPoint = new draw.Point point.x, point.y
        
        # Move the cursor to the place we just clicked
        moveCursorTo @ephemeralSelection.end

    # ## Mouse events for NORMAL DRAG ##

    track.addEventListener 'mousemove', (event) =>
      if @ephemeralSelection?
        point = getPointFromEvent event
        
        if point.from(@ephemeralPoint).magnitude() > MIN_DRAG_DISTANCE

          # Move the ephemeral selection into the selection position
          @selection = @ephemeralSelection
          @ephemeralSelection = null

          # Check to make sure that the selection doesn't contain a cursor
          head = @selection.start
          while head isnt @selection.end
            next_head = head.next
            if head.type is 'cursor' then head.remove() # If there is, remove it
            head = next_head
          
          # If we clicked something in the palette, we need to compute offset etc. with a point that has been computed
          # with offset to the palette.
          if @selection in @paletteBlocks then @ephemeralPoint.add PALETTE_WIDTH, 0; selectionInPalette = true

          # Compute the offset of the selection position from the mouse
          rect = @selection.view.bounds[@selection.view.lineStart]
          offset = @ephemeralPoint.from new draw.Point rect.x, rect.y

          # If we have clicked something in the palette, the clone first.
          if selectionInPalette then @selection = @selection.clone()

          # If we have clicked something floating, then delete it from the list of floating blocks
          for float, i in @floatingBlocks
            if float.block is @selection then @floatingBlocks.splice i, 1; break

          # Move it to nowhere
          moveBlockTo @selection, null

          # Draw it in the drag canvas
          @selection.view.compute()
          @selection.view.draw dragCtx

          # CSS-transform the drag canvas to where it ought to be
          if selectionInPalette
            # If we picked up from the palette, then rect.x is actually relative to the palette
            fixedDest = new draw.Point rect.x - PALETTE_WIDTH, rect.y
          else
            # Otherwise, do as we would with mousemove
            fixedDest = new draw.Point rect.x - @scrollOffset.x, rect.y - @scrollOffset.y

          drag.style.webkitTransform =
            drag.style.mozTransform =
            drag.style.transform = "translate(#{fixedDest.x}px, #{fixedDest.y}px)"
          
          # Redraw the main canvas
          @redraw()

      if @selection?
        # Determine the position of the mouse
        point = getPointFromEvent event

        point.add -@scrollOffset.x, -@scrollOffset.y

        # First we find the highlighted area
        fixedDest = new draw.Point -offset.x + point.x, -offset.y + point.y # Where do we position things exactly in relation to the canvas?

        point.translate @scrollOffset
        dest = new draw.Point -offset.x + point.x, -offset.y + point.y # Where do we position things as related to the way we draw the root tree?

        old_highlight = highlight

        highlight = @tree.find (block) ->
          (not (block.inSocket?() ? false)) and block.view.dropArea? and block.view.dropArea.contains dest

        # If highlight changed, redraw
        if old_highlight isnt highlight then @redraw()

        # Highlight the highlight
        if highlight? then highlight.view.dropHighlightReigon.fill mainCtx, '#fff'

        # CSS-transform the drag canvas to where it ought to be
        drag.style.webkitTransform =
          drag.style.mozTransform =
          drag.style.transform = "translate(#{fixedDest.x}px, #{fixedDest.y}px)"
    
    track.addEventListener 'mouseup', (event) =>
      if @ephemeralSelection?
        @ephemeralSelection = null
        @ephemeralPoint = null

      if @selection?
        # Determine the position of the mouse and the place we want to render the block
        point = getPointFromEvent event
        dest = new draw.Point -offset.x + point.x, -offset.y + point.y

        if highlight?
          # Drop areas signify different things depending on the block that they belong to
          switch highlight.type
            when 'indent'
              head = highlight.end.prev
              while head.type is 'segmentEnd' or head.type is 'segmentStart' or head.type is 'cursor' then head = head.prev

              if head.type is 'newline'
                # There's already a newline here.
                moveBlockTo @selection, highlight.start.next
              else
                # An insert drop signifies that we want to drop the block at the start of the indent
                moveBlockTo @selection, highlight.start.insert new NewlineToken()

            when 'block'
              # A block drop signifies that we want to drop the block after (the end of) the block.
              moveBlockTo @selection, highlight.end.insert new NewlineToken()

            when 'socket'
              # Remove any previously occupying block or text
              if highlight.content()? then highlight.content().remove()

              # Insert
              moveBlockTo @selection, highlight.start
            
            else
              if highlight is @tree
                # We can also drop on the root tree (insert at the start of the program)
                moveBlockTo @selection, @tree.start

                # Don't insert a newline if it would create an empty line at the end of the file.
                unless @selection.end.next is @tree.end
                  @selection.end.insert new NewlineToken()

        else
          # If we have dropped the block in nowhere, append it (and it's floating position) to @floatingBlocks.
          if dest.x > 0
            @floatingBlocks.push
              position: dest
              block: @selection
          
          # If we have dropped the block on the palette, then delete it.
          # This normally requires no operations, but if we have selected it as the lassoSegment,
          # we want to stop drawing its bounding box.
          else if @selection is @lassoSegment
            @lassoSegment = null

        
        # CSS-transform the drag canvas back to the origin
        drag.style.webkitTransform =
          drag.style.mozTransform =
          drag.style.transform = "translate(0px, 0px)"
        
        # Clear the drag canvas
        dragCtx.clearRect 0, 0, drag.width, drag.height

        # If we inserted into root, move the cursor to the end of the selection.
        if highlight?
          # Seek the next newline after the end of this block,
          # which is where we'll want to move the cursor
          # (so that it looks like we put it directly after the block).
          moveCursorTo @selection.end

        # Signify that we are no longer in a NORMAL DRAG
        @selection = null
        
        # Redraw after the selection has been set to null, since @redraw is sensitive to what things are being dragged.
        @redraw()

    # ## Mouse events for LASSO SELECT ##

    getRectFromPoints = (a, b) ->
      return new draw.Rectangle(
        # Take the minimum coordinates for the top-left corner
        Math.min(a.x, b.x), #x
        Math.min(a.y, b.y), #y
        
        # Distances are always positive
        Math.abs(a.x - b.x), #width
        Math.abs(a.y - b.y)) #height

    track.addEventListener 'mousemove', (event) =>
      if @lassoAnchor?
        # Determine the position of the mouse
        point = getPointFromEvent event
        point.add -@scrollOffset.x, -@scrollOffset.y # (position fixed, as in relation to the drag canvas, on which we will draw it)

        # Get the rectangle we want to draw
        rect = getRectFromPoints (new draw.Point @lassoAnchor.x - @scrollOffset.x, @lassoAnchor.y - @scrollOffset.y), point

        # Clear and redraw the lasso on the drag canvas
        dragCtx.clearRect 0, 0, drag.width, drag.height
        dragCtx.strokeStyle = '#00f'
        dragCtx.strokeRect rect.x, rect.y, rect.width, rect.height

    track.addEventListener 'mouseup', (event) =>
      if @lassoAnchor?
        # Determine the position of the mouse
        point = getPointFromEvent event

        # Get the rectangle we want to test
        rect = getRectFromPoints @lassoAnchor, point

        # First pass for lasso segment detection: get intersecting blocks.
        
        # Find the first matching block
        head = @tree.start
        firstLassoed = null
        while head isnt @tree.end
          # A block matches if it intersects the lasso rectangle
          if head.type is 'blockStart' and head.block.view.path.intersects rect
            firstLassoed = head
            break
          head = head.next
        
        # Find the last matching block analagously
        head = @tree.end
        lastLassoed = null
        while head isnt @tree.start
          if head.type is 'blockEnd' and head.block.view.path.intersects rect
            lastLassoed = head
            break
          head = head.prev

        # Unless we have selected anything, give up.
        if firstLassoed? and lastLassoed?
          # Second pass for lasso segment detection: validate the selection and record wrapping blocks as necessary.
          
          tokensToInclude = []

          head = firstLassoed
          while head isnt lastLassoed
            # For each bit of markup, make sure to include both its start token and end token
            switch head.type
              when 'blockStart', 'blockEnd'
                tokensToInclude.push head.block.start
                tokensToInclude.push head.block.end
              when 'indentStart', 'indentEnd'
                tokensToInclude.push head.indent.start
                tokensToInclude.push head.indent.end
              when 'segmentStart', 'segmentEnd'
                tokensToInclude.push head.segment.start
                tokensToInclude.push head.segment.end
            head = head.next

          # Third pass for lasso segment detection: include all necessary tokens demanded by validation

          # Find the first block in tokensToInclude
          head = @tree.start
          while head isnt @tree.end
            if head in tokensToInclude
              firstLassoed = head; break
            head = head.next
          
          # Find the last matching block analagously
          head = @tree.end
          lastLassoed = null
          while head isnt @tree.start
            if head in tokensToInclude
              lastLassoed = head; break
            head = head.prev

          # Fourth pass for lasso segment detection: make sure that we have selected the wrapping block for any indents
          #
          # Note that this will only occur when we have inserted the indentStart at the beginning or indentEnd at the end
          # in the second and third pass. This in turn will occur ONLY when the user has selected multiple blocks belonging to the
          # same wrapping block, and nothing outside it (i.e. the wrapping block of the indent wraps the entire selection).
          #
          # So it suffices to select that entire wrapping block.

          if firstLassoed.type is 'indentStart'
            # Seek the wrapping block for this indent
            depth = 0
            while depth > 0 or head.type isnt 'blockStart' # We need to find the wrapping block, so we keep track of block depth
              # Increment block depth
              if firstLassoed.type is 'blockStart' then depth -= 1
              else if firstLassoed.type is 'blockEnd' then depth += 1

              firstLassoed = firstLassoed.prev
            
            # Set lastLassoed in accordance.
            lastLassoed = firstLassoed.block.end

          if firstLassoed.type is 'indentStart'
            # Seek the wrapping block for this indent
            depth = 0
            while depth > 0 or head.type isnt 'blockEnd' # We need to find the wrapping block, so we keep track of block depth
              # Increment block depth
              if lastLassoed.type is 'blockEnd' then depth -= 1
              else if lastLassoed.type is 'blockStart' then depth += 1
            
            # Set firstLassoed in accordance
            firstLassoed = lastLassoed.block.start

          # Now, insert the actual lasso segment.
          @lassoSegment = new Segment []

          firstLassoed.insertBefore @lassoSegment.start
          lastLassoed.insert @lassoSegment.end

          @redraw()
        
        # Clear the drag canvas
        dragCtx.clearRect 0, 0, drag.width, drag.height

        # If we inserted a lasso segment, move the cursor appropriately
        if @lassoSegment? then moveCursorTo @lassoSegment.end
        
        # Flag that we are no longer in a LASSO SELECT.
        @lassoAnchor = null

        @redraw()


    # ## Utility functions for TEXT INPUT ##

    redrawTextInput = =>
      # Change the edited text
      @editedText.value = @hiddenInput.value

      # Redraw the background (main canvas)
      @redraw()
      
      # Determine the position (coordinate-wise) of the typing cursor
      start = @editedText.view.bounds[_editedInputLine].x +
        mainCtx.measureText(@hiddenInput.value[...@hiddenInput.selectionStart]).width

      end = @editedText.view.bounds[_editedInputLine].x +
        mainCtx.measureText(@hiddenInput.value[...@hiddenInput.selectionEnd]).width
      
      # Draw the typing cursor itself
      if start is end
        # This is just a line
        mainCtx.strokeRect start, @editedText.view.bounds[_editedInputLine].y, 0, INPUT_LINE_HEIGHT
      else
        # This is the translucent rectangle
        mainCtx.fillStyle = 'rgba(0, 0, 256, 0.3'
        mainCtx.fillRect start, @editedText.view.bounds[_editedInputLine].y, end - start, INPUT_LINE_HEIGHT

    setTextInputFocus = (focus) =>
      # Literally set the focus
      @focus = focus

      # Fire the onchange handler
      if @onChange? then @onChange new IceEditorChangeEvent @focus, @focus
      
      # If we just removed the focus, then we are done.
      if @focus is null then return
      
      # Record the line that the focus is on
      _editedInputLine = @focus.view.lineStart

      # Flag whether we are editing handwritten
      @handwritten = @focus.handwritten
      
      if not @focus.content()
        # If the socket is empty, put a text thing in, setting that to the edited text
        @editedText = new TextToken ''
        @focus.start.insert @editedText
      
      else if @focus.content().type is 'text'
        # If the socket is not empty but contains only text, edit that text
        @editedText = @focus.content()

      else
        # Otherwise, we have an error condition.
        throw 'Cannot edit occupied socket.'


      # Find the wrapping block and move the cursor to
      head = @focus.end; depth = 0
      while head.type isnt 'newline' and head.type isnt 'indentEnd' and head.type isnt 'segmentEnd' then head = head.next
      
      if head.type is 'newline' then moveCursorTo head
      else moveCursorBefore head
      
      # Set the contents of the hidden input
      @hiddenInput.value = @editedText.value

      # Focus the hidden input
      setTimeout (=> @hiddenInput.focus()), 0

    setTextInputHead = (point) =>
      textInputHead = Math.round (point.x - @focus.view.bounds[_editedInputLine].x) / mainCtx.measureText(' ').width

      @hiddenInput.setSelectionRange Math.min(textInputAnchor, textInputHead), Math.max(textInputAnchor, textInputHead)

    setTextInputAnchor = (point) =>
      textInputAnchor = textInputHead = Math.round (point.x - @focus.view.bounds[_editedInputLine].x - PADDING) / mainCtx.measureText(' ').width
      @hiddenInput.setSelectionRange textInputAnchor, textInputHead

    # ## Mouse events for TEXT INPUT ##

    track.addEventListener 'mousemove', (event) =>
      if @isEditingText() and textInputSelecting
        # See where the mouse is
        point = getPointFromEvent event
        
        # Set the input head
        setTextInputHead point

        # Redraw
        redrawTextInput()

    track.addEventListener 'mouseup', (event) =>
      if @isEditingText()
        textInputSelecting = false

    # ## Mouse events for SCROLLING ##

    track.addEventListener 'mousewheel', (event) =>
      @clear()

      if event.wheelDelta > 0
        if @scrollOffset.y >= 100
          @scrollOffset.add 0, -100
          mainCtx.translate 0, 100
        else
          # If we would go past the top of the file, just scroll to exactly the top of the file.
          mainCtx.translate 0, @scrollOffset.y
          @scrollOffset.y = 0
      else
        @scrollOffset.add 0, 100
        mainCtx.translate 0, -100

      @redraw()

  setValue: (value) ->
    @tree = coffee.parse(value).segment
    @redraw()

  getValue: -> @tree.toString()

window.onload = ->
  # ## Tests ##
  window.editor = new Editor document.getElementById('editor'), (coffee.parse(paletteElement).next.block for paletteElement in [
    '''
    for i in [1..10]
      alert 'hello'
    '''
    '''
    alert 'hello'
    '''
    '''
    if a is b
      alert 'hi'
    else
      alert 'bye'
    '''
    '''
    a = b
    '''
  ])
  editor.setValue '''
  for i in [1..10]
    if i % 2 is 0
      alert i
      alert 'bye'
    else
      alert 'fizz'
    alert 'buzz'
  '''

  editor.onChange = ->
    document.getElementById('out').value = editor.getValue()

  document.getElementById('out').addEventListener 'input', ->
    try
      editor.setValue this.value

  document.getElementById('undo').addEventListener 'click', ->
    editor.undo()
