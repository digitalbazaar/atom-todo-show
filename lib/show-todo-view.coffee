# This file handles all the fetching and displaying logic. It doesn't handle any of the pane magic.
# Pane magic happens in show-todo.coffee.
# Markup is in template/show-todo-template.html
# Styling is in the stylesheets folder.
#
# FIXME: Realizing this is some pretty nasty code. This should really, REALLY be cleaned up. Testing should help.
# Also, having a greater understanding of Atom should help.

path = require 'path'
{Emitter, Disposable, CompositeDisposable, Point} = require 'atom'
{$, $$$, TextEditorView, ScrollView} = require 'atom-space-pen-views'
{allowUnsafeEval, allowUnsafeNewFunction} = require 'loophole'
Q = require 'q'
fs = require 'fs-plus'
slash = require 'slash'
ignore = require 'ignore'

module.exports =
class ShowTodoView extends ScrollView
  @content: ->
    @div class: 'show-todo-preview native-key-bindings', tabindex: -1

  constructor: ({@filePath}) ->
    super
    @handleEvents()
    @emitter = new Emitter
    @disposables = new CompositeDisposable

  destroy: ->
    @detach()
    @disposables.dispose()

  getTitle: ->
    "Todo-Show Results"

  getURI: ->
    "todolist-preview://#{@getPath()}"

  getPath: ->
    "TODOs"
  
  getProjectPath: ->
    atom.project.getPaths()[0]

  onDidChangeTitle: -> new Disposable()
  onDidChangeModified: -> new Disposable()

  resolveImagePaths: (html) =>
    html = $(html)
    imgList = html.find("img")

    for imgElement in imgList
      img = $(imgElement)
      src = img.attr('src')
      continue if src.match /^(https?:\/\/)/
      img.attr('src', path.resolve(path.dirname(@getPath()), src))

    html

  # currently broken. FIXME: Remove or replace
  resolveJSPaths: (html) =>
    html = $(html)

    # scrList = html.find("#mainScript")
    scrList = [html[5]]

    for scrElement in scrList
      js = $(scrElement)
      src = js.attr('src')
      # continue if src.match /^(https?:\/\/)/
      js.attr('src', path.resolve(path.dirname(@getPath()), src))
    html

  showLoading: ->
    @loading = true
    @html $$$ ->
      @div class: 'markdown-spinner', 'Loading Todos...'

  # Get the regexes to look for from settings
  # @FIXME: Add proper comments
  # @param settingsRegexes {array} - An array of regexes from settings.
  buildRegexLookups: (settingsRegexes) ->
    regexes = [] #[{title, regex, results}]

    for regex, i in settingsRegexes
      match = {
        'title': regex
        'regex': settingsRegexes[i+1]
        'results': []
      }
      _i = _i+1    #_ overrides the one that coffeescript actually creates. Seems hackish. FIXME: maybe just use modulus
      regexes.push(match)

    return regexes

  # Pass in string and returns a proper RegExp object
  makeRegexObj: (regexStr) ->
    # extract the regex pattern
    pattern = regexStr.match(/\/(.+)\//)?[1] #extract anything between the slashes
    # extract the flags (after the last slash)
    flags = regexStr.match(/\/(\w+$)/)?[1] #extract any words after the last slash. Flags are optional

    # abort if there's no valid pattern
    return false unless pattern

    return new RegExp(pattern, flags)

  # Scan the project for the regex that is passed
  # returns a promise that the project scan generates
  # @TODO: Improve the param name. Confusing
  fetchRegexItem: (lookupObj) ->
    regexObj = @makeRegexObj(lookupObj.regex)

    # abort if there's no valid pattern
    return false unless regexObj

    # handle ignores from settings
    ignoresFromSettings = atom.config.get('todo-show.ignoreThesePaths')
    hasIgnores = ignoresFromSettings?.length > 0
    ignoreRules = ignore({ ignore:ignoresFromSettings })
    
    return atom.workspace.scan regexObj, (e) ->
      # check against ignored paths
      include = true
      pathToTest = slash(e.filePath.substring(atom.project.getPaths()[0].length))
      if (hasIgnores && ignoreRules.filter([pathToTest]).length == 0)
        include = false
        
      if include
        # loop through the results in the file, strip out 'todo:', and allow an optional space after todo:
        # regExMatch.matchText = regExMatch.matchText.match(regexObj)[1] for regExMatch in e.matches
        for regExMatch in e.matches
          # strip out the regex token from the found phrase (todo, fixme, etc)
          # FIXME: I have no idea why this requires a stupid while loop. Figure it out and/or fix it.
          while (match = regexObj.exec(regExMatch.matchText))
            regExMatch.matchText = match[1].trim()
        
        lookupObj.results.push(e) # add it to the array of results for this regex

  renderTodos: ->
    @showLoading()

    # fetch the reges from the settings
    regexes = @buildRegexLookups(atom.config.get('todo-show.findTheseRegexes'))

    # @FIXME: abstract this into a separate, testable function?
    promises = []
    for regexObj in regexes
      # scan the project for each regex, and get a promise in return
      promise = @fetchRegexItem(regexObj)
      promises.push(promise) # create array of promises so we can listen for completion

    # fire callback when ALL project scans are done
    Q.all(promises).then () =>
      @regexes = regexes
      
      # wasn't able to load 'dust' properly for some reason
      dust = require('dust.js') #templating engine

      # template = hogan.compile("Hello {name}!");

      # team = ['jamis', 'adam', 'johnson']

      # load up the template
      # path.resolve __dirname, '../template/show-todo-template.html'
      templ_path = path.resolve(__dirname, '../template/show-todo-template.html')
      if ( fs.isFileSync(templ_path) )
        template = fs.readFileSync(templ_path, {encoding: "utf8"})

      # FIXME: Add better error handling if the template fails to load
      compiled = dust.compile(template, "todo-template")

      # is this step necessary? Appears to be...
      dust.loadSource(compiled)

      # content & filters
      context = {
        # make the path to the result relative
        "filterPath": (chunk, context, bodies) ->
          chunk.tap((data) ->
            # make it relative
            atom.project.relativize(data)
          ).render(bodies.block, context).untap()
        ,
        "results": regexes # FIXME: fix the sort order in the results
        # "todo_items": todoArray,
        # "fixme_items": fixmeArray,
        # "changed_items": changedArray,
        # "todo_items_length": todo_total_length,
        # "fixme_items_length": fixme_total_length,
        # "changed_items_length": changed_total_length
      }

      # console.log('VM', vm);
      # vm.evalInThisContext(console.log('hi something in vm'));

      # render the template
      # doSomething: ->

      dust.render "todo-template", context, (err, out) =>
        @loading = false
        
        # console.log 'err', err
        # console.log('content to be rendered', out);
        # allowUnsafeEval  ->
        # console.log('hi ho')
        # out = @resolveJSPaths out #resolve the relative JS paths for external <script> in view
        @html(out)
        # @html 'hi'

      # vm.evalInThisContext("doSomething()");

  handleEvents: ->
    atom.commands.add @element,
      'core:save-as': (event) =>
        event.stopPropagation()
        @saveAs()
      'core:refresh': (event) =>
        event.stopPropagation()
        @renderTodos()
    
    @on 'click', '.file_url a',  (e) =>
      link = e.target
      @openPath(link.dataset.uri, link.dataset.coords.split(','))
    @on 'click', '.todo-save-as', =>
      @saveAs()
    @on 'click', '.todo-refresh', =>
      @renderTodos()

  # Open a new window, and load the file that we need.
  # we call this from the results view. This will open the result file in the left pane.
  openPath: (filePath, cursorCoords) ->
    return unless filePath

    atom.workspace.open(filePath, split: 'left').done =>
      @moveCursorTo(cursorCoords)

  # Open document and move cursor to positon
  moveCursorTo: (cursorCoords) ->
    lineNumber = parseInt(cursorCoords[0])
    charNumber = parseInt(cursorCoords[1])

    if textEditor = atom.workspace.getActiveTextEditor()
      position = [lineNumber, charNumber]
      textEditor.setCursorBufferPosition(position, autoscroll: false)
      textEditor.scrollToCursorPosition(center: true)
  
  getMarkdown: ->
    projectPath = @getProjectPath()
    
    @regexes.map((regex) ->
      return unless regex.results.length
      
      out = '\n## ' + regex.title + '\n\n'
      
      regex.results?.map((result) ->
        relativePath = path.relative(projectPath, result.filePath)
        
        result.matches?.map((match) ->
          out += '- ' + match.matchText
          out += ' _(' + relativePath + ')_\n'
        )
      )
      out
    ).join("")
  
  saveAs: ->
    return if @loading
    
    filePath = path.parse(@getPath()).name + '.txt'
    if @getProjectPath()
      filePath = path.join(@getProjectPath(), filePath)

    if outputFilePath = atom.showSaveDialogSync(filePath)
      fs.writeFileSync(outputFilePath, @getMarkdown())
      atom.workspace.open(outputFilePath)
