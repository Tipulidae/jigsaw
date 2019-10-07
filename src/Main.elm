port module Main exposing (..)


import Set as S
import Dict as D
import Array as A
import Browser
import Browser.Events
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Json.Decode
import Random
import Random.List
import Random.Set
import Random.Extra
import File exposing (File)
import File.Select
import Task

import Point exposing (Point)
import Util exposing (takeFirst)
import Edge exposing (EdgePoints, makeEdgePoints, pieceCurveFromPieceId)

-- MAIN
main =
  Browser.element
    { init = init
    , update = update
    , view = view
    , subscriptions = subscriptions
    }


-- MODEL

type Msg
  = MouseDown Point Keyboard
  | MouseMove Point
  | MouseUp
  | Scramble
  | KeyChanged Bool Key
  | PickImage
  | GotImage File
  | FinishedLoading ThingThatCanLoad
  | Cheat Int

type alias Keyboard =
  { shift : Bool
  , ctrl : Bool
  }

type alias Model =
  { cursor : Maybe Point
  , pieceGroups : D.Dict Int PieceGroup
  , selected : Selected
  , maxZLevel : Int
  , image : JigsawImage
  , width : Int
  , height : Int
  , snapDistance : Float
  , selectionBox : SelectionBox
  , seed : Random.Seed
  , visibleGroups : S.Set Int
  , keyboard : Keyboard
  , loading : LoadStatus
  }

type alias JigsawImage =
  { path : String
  , width : Int
  , height : Int
  , xpieces : Int
  , ypieces : Int
  , scale : Float
  }

type alias PieceGroup =
  { id : Int
  , members : List Int
  , neighbours : S.Set Int
  , position : Point
  , isSelected : Bool
  , zlevel : Int
  , visibilityGroup : Int
  }

type ThingThatCanLoad
  = ImageUrl String
  | ImageDiv
  | CanvasDraw (Int, Int)

type LoadStatus
  = ParsingImageUrl
  | LoadingImage
  | DrawingCanvas
  | Finished

nextLoadStatus : LoadStatus -> LoadStatus
nextLoadStatus status =
  case status of
    ParsingImageUrl -> LoadingImage
    LoadingImage -> DrawingCanvas
    DrawingCanvas -> Finished
    Finished -> ParsingImageUrl

type SelectionBox
  = Normal Box
  | Inverted Box
  | NullBox

type alias Box =
  { staticCorner : Point
  , movingCorner : Point
  , selectedIds : S.Set Int
  }

type Selected
  = Multiple
  | Single Int
  | NullSelection


type alias JSMessage =
  { contours : List String
  , nx : Int
  , ny : Int
  }

boxTopLeft : Box -> Point
boxTopLeft box =
  Point
    (min box.staticCorner.x box.movingCorner.x)
    (min box.staticCorner.y box.movingCorner.y)

boxBottomRight : Box -> Point
boxBottomRight box =
  Point
    (max box.staticCorner.x box.movingCorner.x)
    (max box.staticCorner.y box.movingCorner.y)

-- Until I figure out how to handle index out of bounds
-- exceptions more elegantly
defaultPieceGroup : PieceGroup
defaultPieceGroup =
  { position = Point 0 0
  , isSelected = False
  , zlevel = -1
  , id = -10
  , neighbours = S.empty
  , members = []
  , visibilityGroup = -1
  }


-- INIT

init : () -> ( Model, Cmd Msg )
init () =
  let
    image =
      { path = "resources/hongkong.jpg"
      , width = 6000
      , height = 4000
      , xpieces = 60
      , ypieces = 40
      , scale = 0.2
      }
    model =
      resetModel image (Random.initialSeed 0)
  in
  ( model, Cmd.none )

resetModel : JigsawImage -> Random.Seed -> Model
resetModel image seed =
  let
    (w, h) = (1800, 1100)
    (nx, ny) = (image.xpieces, image.ypieces)

    (positions, seed1) = generateRandomPiecePositions w h image seed
    (zlevels, seed2) = generateRandomZLevels (nx * ny) seed1
  in
    { cursor = Nothing
    , pieceGroups = createPieceGroups image positions zlevels
    , selected = NullSelection
    , maxZLevel = nx * ny
    , image = image
    , width = w
    , height = h
    , snapDistance = 30.0
    , selectionBox = NullBox
    , seed = seed2
    , visibleGroups = S.fromList [-1]
    , keyboard = { shift = False, ctrl = False }
    , loading = LoadingImage
    }


generateRandomPiecePositions : Int -> Int -> JigsawImage -> Random.Seed -> (List Point, Random.Seed)
generateRandomPiecePositions w h image seed =
  let
    n = image.xpieces * image.ypieces
    xmin = 0
    xmax = toFloat w - (toFloat image.width) / (toFloat image.xpieces)
    ymin = 0
    ymax = toFloat h - (toFloat image.height) / (toFloat image.ypieces)
  in
    Random.step (Point.randomPoints n xmin xmax ymin ymax) seed

generateRandomZLevels : Int -> Random.Seed -> (List Int, Random.Seed)
generateRandomZLevels n seed =
  Random.step (Random.List.shuffle <| List.range 0 (n - 1)) seed

createPieceGroups : JigsawImage -> List Point -> List Int -> D.Dict Int PieceGroup
createPieceGroups image positions levels =
  let
    nx = image.xpieces
    ny = image.ypieces
    n = nx*ny

    range =
      List.range 0 (n - 1)
    zlevels =
      if List.length levels < n then
        range
      else
        levels
    neighbourOffsets =
      [ -nx, -1, 1, nx ]
    possibleNeighbours i =
      List.map ((+) i) neighbourOffsets
    isRealNeighbour i x =
       x >= 0 && x < n &&
      Point.taxiDist
        ( pieceIdToPoint i image.xpieces )
        ( pieceIdToPoint x image.xpieces ) == 1
    onePieceGroup i position zlevel =
      ( i
      , { position = Point.sub position <| pieceIdToOffset image i
        , isSelected = False
        , id = i
        , zlevel = zlevel
        , members = [ i ]
        , neighbours = S.filter (isRealNeighbour i) <| S.fromList (possibleNeighbours i)
        , visibilityGroup = -1
        }
      )

  in
    D.fromList <| List.map3 onePieceGroup range positions zlevels

pieceIdToPoint : Int -> Int -> Point
pieceIdToPoint id xpieces =
  Point (toFloat (modBy xpieces id)) (toFloat (id // xpieces))

pieceIdToOffset : JigsawImage -> Int -> Point
pieceIdToOffset image id =
  let
    pieceWidth =  image.scale * (toFloat image.width) / (toFloat image.xpieces)
    pieceHeight = image.scale * (toFloat image.height) / (toFloat image.ypieces)
  in
    Point
      (pieceWidth * (toFloat <| modBy image.xpieces id))
      (pieceHeight * (toFloat <| id // image.xpieces))


isPieceInsideBox : JigsawImage -> Point -> Point -> Point -> Int -> Bool
isPieceInsideBox image pos boxTL boxBR id =
  let
    pieceWidth = image.scale * (toFloat image.width) / (toFloat image.xpieces)
    pieceHeight = image.scale * (toFloat image.height) / (toFloat image.ypieces)
    pieceTL = Point.add pos <| pieceIdToOffset image id
    pieceBR = Point.add pieceTL <| Point pieceWidth pieceHeight
  in
    ( pieceTL.x <= boxBR.x ) &&
    ( pieceTL.y + 100 <= boxBR.y ) &&
    ( pieceBR.x >= boxTL.x ) &&
    ( pieceBR.y + 100 >= boxTL.y )

isPieceGroupInsideBox : JigsawImage -> Point -> Point -> PieceGroup -> Bool
isPieceGroupInsideBox image boxTL boxBR pieceGroup =
  List.any (isPieceInsideBox image pieceGroup.position boxTL boxBR) pieceGroup.members

isPointInsidePiece : JigsawImage -> Point -> Point -> Int -> Bool
isPointInsidePiece image point pos id =
  let
    pieceWidth = image.scale * (toFloat image.width) / (toFloat image.xpieces)
    pieceHeight = image.scale * (toFloat image.height) / (toFloat image.ypieces)
    pieceTL = Point.add pos <| pieceIdToOffset image id
    pieceBR = Point.add pieceTL <| Point pieceWidth pieceHeight
  in
    ( pieceTL.x <= point.x ) &&
    ( pieceTL.y + 100 <= point.y ) &&
    ( pieceBR.x >= point.x ) &&
    ( pieceBR.y + 100 >= point.y )

isPointInsidePieceGroup visibleGroups image point pieceGroup =
  (S.member pieceGroup.visibilityGroup visibleGroups) &&
  (List.any (isPointInsidePiece image point pieceGroup.position) pieceGroup.members)


-- SUBSCRIPTIONS

keyDecoder isDown key =
  case key of
    "0" -> KeyChanged isDown (Number 0)
    "1" -> KeyChanged isDown (Number 1)
    "2" -> KeyChanged isDown (Number 2)
    "3" -> KeyChanged isDown (Number 3)
    "4" -> KeyChanged isDown (Number 4)
    "5" -> KeyChanged isDown (Number 5)
    "6" -> KeyChanged isDown (Number 6)
    "7" -> KeyChanged isDown (Number 7)
    "8" -> KeyChanged isDown (Number 8)
    "9" -> KeyChanged isDown (Number 9)
    "Control" -> KeyChanged isDown Control
    "Shift" -> KeyChanged isDown Shift
    _ -> KeyChanged isDown Other


subscriptions : Model -> Sub Msg
subscriptions model =
  let
    trackMouseMovement =
      if model.cursor /= Nothing then
        Browser.Events.onMouseMove
          <| Json.Decode.map2 (\x y -> MouseMove (Point (toFloat x) (toFloat y)))
            (Json.Decode.field "pageX" Json.Decode.int)
            (Json.Decode.field "pageY" Json.Decode.int)
      else
        Sub.none

    trackMouseDown =
      Browser.Events.onMouseDown
        <| Json.Decode.map4 (\x y shift ctrl -> MouseDown (Point (toFloat x) (toFloat y)) {shift=shift, ctrl=ctrl})
          (Json.Decode.field "pageX" Json.Decode.int)
          (Json.Decode.field "pageY" Json.Decode.int)
          (Json.Decode.field "shiftKey" Json.Decode.bool)
          (Json.Decode.field "ctrlKey" Json.Decode.bool)

    trackMouseUp =
      Browser.Events.onMouseUp (Json.Decode.succeed MouseUp)
  in
  Sub.batch
    [ trackMouseMovement
    , trackMouseDown
    , trackMouseUp
    , Browser.Events.onKeyDown (Json.Decode.map (keyDecoder True) (Json.Decode.field "key" Json.Decode.string))
    , Browser.Events.onKeyUp (Json.Decode.map (keyDecoder False) (Json.Decode.field "key" Json.Decode.string))
    , canvasDrawn (FinishedLoading << CanvasDraw)
    ]

-- UPDATE

type Key
  = Number Int
  | Control
  | Shift
  | Other


createJsMessage : Int -> Int -> D.Dict Int PieceGroup -> A.Array EdgePoints -> JSMessage
createJsMessage nx ny pieceGroups edgePoints =
  let
    contour pid =
      pieceCurveFromPieceId nx ny edgePoints pid

    contours =
      List.concatMap (\pg -> List.map contour pg.members) <| D.values pieceGroups

  in
  {contours = contours, nx = nx, ny = ny}

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
  case msg of
    Cheat number ->
      ( cheatManyTimes number model
      , Cmd.none
      )
    FinishedLoading thing ->
      let
        oldImage = model.image
        newLoading = nextLoadStatus model.loading
      in
      case thing of
        ImageUrl url ->
          ( {model | image = {oldImage | path = url}, loading = newLoading}
          , Cmd.none
          )
        ImageDiv ->
          let
            nx = model.image.xpieces
            ny = model.image.ypieces
            numberOfEdges = 2 * nx * ny - nx - ny
            (edgePoints, newSeed) = makeEdgePoints numberOfEdges model.seed
          in
          ( {model | loading = newLoading, seed = newSeed}
          , drawPiecesInCanvas <| createJsMessage nx ny model.pieceGroups edgePoints
          )
        CanvasDraw (x, y) ->
          let
            newModel = resetModel {oldImage | width = x, height = y} model.seed
          in
          ( {newModel | loading = newLoading}
          , Cmd.none )

    PickImage ->
      ( model
      , File.Select.file ["image/*"] GotImage )
    GotImage file ->
      ( {model | loading = ParsingImageUrl}
      , Task.perform (FinishedLoading << ImageUrl) (File.toUrl file))

    KeyChanged isDown key ->
      let
        assignVisibilityGroup visibilityGroup _ pg  =
          if pg.isSelected && pg.visibilityGroup /= visibilityGroup then
            {pg | visibilityGroup = visibilityGroup, isSelected = False}
          else
            pg

        newPieceGroups visibilityGroup =
          D.map (assignVisibilityGroup visibilityGroup) model.pieceGroups

        toggleVisibilityOf group number =
          if S.member number group then
            S.remove number group
          else
            S.insert number group
      in
      case key of
        Number x ->
          case (model.keyboard.ctrl, isDown) of
            (True, True) ->
              ( {model | pieceGroups = newPieceGroups x}, Cmd.none)
            (False, True) ->
              ( {model | visibleGroups = toggleVisibilityOf model.visibleGroups x}, Cmd.none )
            (_, False) ->
              ( model, Cmd.none )

        Control ->
          let
            newKeyboard keyboard = {keyboard | ctrl = isDown}
          in
            ( {model | keyboard = newKeyboard model.keyboard}, Cmd.none )
        Shift ->
          let
            newKeyboard keyboard = {keyboard | shift = isDown}
          in
            ( {model | keyboard = newKeyboard model.keyboard}, Cmd.none )
        Other -> ( model, Cmd.none )

    Scramble ->
      let
        newModel = resetModel model.image model.seed
      in
        ( { newModel | loading = Finished }, Cmd.none )

    MouseDown coordinate keyboard ->
      let
        clickedPieceGroup =
          D.values model.pieceGroups
            |> List.filter (isPointInsidePieceGroup model.visibleGroups model.image coordinate)
            |> List.foldl (\a b -> if a.zlevel > b.zlevel then a else b) defaultPieceGroup

        clickedOnBackground =
          clickedPieceGroup.id == -10

        newModel =
          if clickedOnBackground then
            startSelectionBox model coordinate keyboard
          else
            selectPieceGroup model clickedPieceGroup.id coordinate keyboard
      in
        ( newModel
        , Cmd.none )

    MouseUp ->
      let
        newModel =
          case model.selectionBox of
          Normal box ->
            { model
            | selectionBox = NullBox
            , cursor = Nothing
            , selected = currentSelection model.pieceGroups
            }
          Inverted box ->
            { model
            | selectionBox = NullBox
            , cursor = Nothing
            , selected = currentSelection model.pieceGroups
            }
          NullBox ->
            case model.selected of
              Multiple ->
                { model | cursor = Nothing }
              NullSelection ->
                { model | cursor = Nothing }
              Single id ->
                { model
                  | cursor = Nothing
                  , selected = NullSelection
                  , pieceGroups =
                      D.get id model.pieceGroups
                      |> Maybe.withDefault defaultPieceGroup
                      |> snapToNeighbour model
                }
      in
        ( newModel, Cmd.none )

    MouseMove newPos ->
      case model.cursor of
        Nothing ->
          ( model, Cmd.none )

        Just oldPos ->
          case model.selectionBox of
            NullBox ->
              let
                movePieceGroup : Int -> PieceGroup -> PieceGroup
                movePieceGroup _ pg =
                  if pg.isSelected then
                    { pg | position = Point.add pg.position <| Point.sub newPos oldPos}
                  else
                    pg
                updatedModel =
                  { model
                  | cursor = Just newPos
                  , pieceGroups = D.map movePieceGroup model.pieceGroups
                  }
              in
                ( updatedModel, Cmd.none )

            Normal box ->
              let
                tl = boxTopLeft box
                br = boxBottomRight box
                selectPiece _ pg =
                  let
                    isVisible = S.member pg.visibilityGroup model.visibleGroups
                    originallySelected = S.member pg.id box.selectedIds
                    insideBoxNow = isPieceGroupInsideBox model.image tl br pg
                    newSelectionStatus =
                      if isVisible then
                        if originallySelected && insideBoxNow then
                          True
                        else if originallySelected && not insideBoxNow then
                          True
                        else if not originallySelected && insideBoxNow then
                          True
                        else
                          False
                      else
                        False
                  in
                    { pg | isSelected = newSelectionStatus }
                updatedPieceGroups =
                  D.map selectPiece model.pieceGroups
              in
              ( { model
                | selectionBox = Normal {box | movingCorner = newPos}
                , pieceGroups = updatedPieceGroups
                }
              , Cmd.none )
            Inverted box ->
              let
                tl = boxTopLeft box
                br = boxBottomRight box
                selectPiece _ pg =
                  let
                    isVisible = S.member pg.visibilityGroup model.visibleGroups
                    originallySelected = S.member pg.id box.selectedIds
                    insideBoxNow = isPieceGroupInsideBox model.image tl br pg
                    newSelectionStatus =
                      if isVisible then
                        if originallySelected && insideBoxNow then
                          False
                        else if originallySelected && not insideBoxNow then
                          True
                        else if not originallySelected && insideBoxNow then
                          True
                        else
                          False
                      else
                        False
                  in
                    { pg | isSelected = newSelectionStatus }

                updatedPieceGroups =
                  D.map selectPiece model.pieceGroups
              in
              ( { model
                | selectionBox = Inverted {box | movingCorner = newPos}
                , pieceGroups = updatedPieceGroups
                }
              , Cmd.none )


selectPieceGroup : Model -> Int -> Point -> Keyboard -> Model
selectPieceGroup model id coordinate keyboard =
  let
    clickedPieceGroup =
      D.get id model.pieceGroups
        |> Maybe.withDefault defaultPieceGroup

    wasSelectedBefore =
      clickedPieceGroup.isSelected

    shouldStartDragging =
      wasSelectedBefore && model.selected == Multiple

    fixZlevels =
      D.insert id { clickedPieceGroup | zlevel = model.maxZLevel}

    selectClickedPieceGroup =
      D.insert id { clickedPieceGroup | isSelected = True }

    invertClickedPieceGroup =
      D.insert id { clickedPieceGroup | isSelected = not clickedPieceGroup.isSelected }

    deselectAllOther =
      D.map (\key pg -> {pg | isSelected = key == id})

    newPieceGroups =
      if keyboard.ctrl then
        invertClickedPieceGroup
      else if keyboard.shift then
        selectClickedPieceGroup << fixZlevels
      else if shouldStartDragging then
        fixZlevels
      else
        deselectAllOther << fixZlevels
  in
    { model
    | maxZLevel = model.maxZLevel + 1
    , cursor = Just coordinate
    , selected = currentSelection <| newPieceGroups model.pieceGroups
    , pieceGroups = newPieceGroups model.pieceGroups
    }

startSelectionBox : Model -> Point -> Keyboard -> Model
startSelectionBox model coordinate keyboard =
  let
    ids = allSelectedPieceGroups model.pieceGroups
      |> D.keys
      |> S.fromList
  in
  if keyboard.ctrl then
    { model
      | cursor = Just coordinate
      , selectionBox = Inverted
        { staticCorner = coordinate
        , movingCorner = coordinate
        , selectedIds = ids
        }
      }
  else if keyboard.shift then
    { model
      | cursor = Just coordinate
      , selectionBox = Normal
        { staticCorner = coordinate
        , movingCorner = coordinate
        , selectedIds = ids
        }
    }
  else
    { model
      | cursor = Just coordinate
      , selected = NullSelection
      , pieceGroups = D.map (\_ pg -> {pg | isSelected = False}) model.pieceGroups
      , selectionBox = Normal
        { staticCorner = coordinate
        , movingCorner = coordinate
        , selectedIds = S.empty
        }
    }


snapToNeighbour : Model -> PieceGroup -> D.Dict Int PieceGroup
snapToNeighbour model selected =
  let
    neighbourDistance : PieceGroup -> (Float, PieceGroup)
    neighbourDistance neighbour =
      ( Point.dist selected.position neighbour.position
      , neighbour)

    neighbourFromId : Int -> PieceGroup
    neighbourFromId id =
      Maybe.withDefault defaultPieceGroup
        <| D.get id model.pieceGroups

    distanceToSelected : List (Float, PieceGroup)
    distanceToSelected =
      List.map (neighbourDistance << neighbourFromId) (S.toList selected.neighbours)

    smallEnough : (Float, a) -> Bool
    smallEnough (distance, _) =
      distance < model.snapDistance

    closeNeighbour : Maybe PieceGroup
    closeNeighbour =
      case takeFirst smallEnough distanceToSelected of
        Nothing -> Nothing
        Just (_, neighbour) ->
          if S.member neighbour.visibilityGroup model.visibleGroups then
            Just neighbour
          else
            Nothing

    merge : PieceGroup -> PieceGroup -> PieceGroup
    merge a b =
      let
        newMembers = b.members ++ a.members
        newNeighbours = S.diff (S.union b.neighbours a.neighbours) (S.fromList newMembers)
      in
        { b
          | isSelected = False
          , members = newMembers
          , neighbours = newNeighbours
          , zlevel = a.zlevel}
  in
  case closeNeighbour of
    Just neighbour ->
      let
        fixNeighbours : S.Set Int -> Int -> Int -> S.Set Int
        fixNeighbours neighbours wrong right =
          if S.member wrong neighbours then
            S.insert right <| S.remove wrong neighbours
          else
            neighbours

        replaceSelectedIdWithNeighbourId _ pg =
            {pg | neighbours = fixNeighbours pg.neighbours selected.id neighbour.id}

      in
        merge selected neighbour
          |> Util.flip (D.insert neighbour.id) model.pieceGroups
          |> D.remove selected.id
          |> D.map replaceSelectedIdWithNeighbourId

    Nothing ->
      model.pieceGroups


allSelectedPieceGroups pieceGroups =
  D.filter (\_ pg -> pg.isSelected) pieceGroups

currentSelection : D.Dict Int PieceGroup -> Selected
currentSelection pieceGroups =
  case D.keys <| allSelectedPieceGroups pieceGroups of
    [] -> NullSelection
    id :: [] -> Single id
    _ -> Multiple

cheat : Model -> Model
cheat model =
  let
    (randomPieceGroup, seed1) =
      case Random.step (Random.Extra.sample <| D.values model.pieceGroups) model.seed of
        (Nothing, newSeed) -> (defaultPieceGroup, newSeed)
        (Just pg, newSeed) -> (pg, newSeed)

    (randomNeighbourId, seed2) =
      case (Random.step (Random.Set.sample randomPieceGroup.neighbours) seed1) of
        (Nothing, newSeed) -> (0, newSeed)
        (Just id, newSeed) -> (id, newSeed)

    neighbour =
      D.get randomNeighbourId model.pieceGroups
        |> Maybe.withDefault defaultPieceGroup

    movePieceGroup pg =
      {pg | position = neighbour.position}

    newPieceGroups =
      snapToNeighbour model (movePieceGroup <| randomPieceGroup)
  in
  if D.size model.pieceGroups > 1 then
    { model | seed = seed2, pieceGroups = newPieceGroups }
  else
    model

cheatManyTimes : Int -> Model -> Model
cheatManyTimes n model =
  let
    cheatOnce _ oldModel =
      cheat oldModel
  in
    List.foldl cheatOnce model <| List.repeat n 0


-- VIEW

view : Model -> Html Msg
view model =
  Html.div
    ( turnOffTheBloodyImageDragging )
    [
      viewMenu model
    , Html.div
      [ Html.Attributes.style "width" <| String.fromInt model.image.width ++ "px"
      , Html.Attributes.style "height" <| String.fromInt model.image.height ++ "px"
      , Html.Attributes.style "position" "absolute"
      , Html.Attributes.style "top" "100px"
      , Html.Attributes.style "left" "0px"
      ]
      (
        (loadingScreen model.loading) ::
        (preloadImage model.image) ::
        (viewDiv model) ++
        (viewSelectionBox model)
      )
    ]

loadingScreen : LoadStatus -> Html Msg
loadingScreen loading =
  let
    display =
      case loading of
        Finished -> "none"
        _ -> "block"

    loadText =
      case loading of
        ParsingImageUrl -> "Parsing Image URL"
        LoadingImage -> "Loading Image"
        DrawingCanvas -> "Drawing canvas"
        Finished -> "Finished loading!"
  in
    Html.h1
    [ Html.Attributes.style "display" display ]
    [ Html.text <| loadText ]

preloadImage image =
  Html.img
  [ Html.Events.on "load" <| Json.Decode.succeed <| FinishedLoading ImageDiv
  , Html.Attributes.id "jigsawImage"
  , Html.Attributes.style "display" "none"
  , Html.Attributes.src image.path
  ]
  []


turnOffTheBloodyImageDragging =
  [ Html.Attributes.style "-webkit-user-select" "none"
  , Html.Attributes.style "-khtml-user-select" "none"
  , Html.Attributes.style "-moz-user-select" "none"
  , Html.Attributes.style "-o-user-select" "none"
  , Html.Attributes.style "user-select" "none"
  , Html.Attributes.draggable "false"
  ]

viewSelectionBox model =
  let
    divSelectionBox box color =
      let
        topLeft = boxTopLeft box
        bottomRight = boxBottomRight box
        top = max 100 topLeft.y
        coord = Point.sub bottomRight topLeft
      in
        Html.div
          ([ Html.Attributes.style "width" <| Point.xToPixel coord
          , Html.Attributes.style "height" <| String.fromInt (floor (bottomRight.y - top)) ++ "px"
          , Html.Attributes.style "background-color" color
          , Html.Attributes.style "border-style" "dotted"
          , Html.Attributes.style "top" <| String.fromInt (floor top - 100) ++ "px"
          , Html.Attributes.style "left" <| Point.xToPixel topLeft
          , Html.Attributes.style "z-index" <| String.fromInt (model.maxZLevel + 1)
          , Html.Attributes.style "position" "absolute"
          ] ++ turnOffTheBloodyImageDragging)
          []
  in
    case model.selectionBox of
      Normal box ->
        [ divSelectionBox box "rgba(0,0,255,0.2)" ]
      Inverted box ->
        [ divSelectionBox box "rgba(0,255,0,0.2)" ]
      NullBox ->
        []

viewDiv : Model -> List (Html Msg)
viewDiv model =
  let
    visibility =
      case model.loading of
        Finished -> Html.Attributes.style "display" "block"
        _ -> Html.Attributes.style "display" "none"
    imageWidth = model.image.scale * toFloat model.image.width
    imageHeight = model.image.scale * toFloat model.image.height
    pieceWidth =  imageWidth / toFloat model.image.xpieces
    pieceHeight = imageHeight / toFloat model.image.ypieces

    viewPieceGroup : PieceGroup -> List ({pid : Int, html : Html Msg})
    viewPieceGroup pg =
      let
        display = if S.member pg.visibilityGroup model.visibleGroups then "block" else "none"
        zlevel = String.fromInt pg.zlevel
      in
      List.map (pieceDiv pg.position display zlevel) <| List.sort pg.members

    pieceDiv : Point -> String -> String -> Int -> {pid : Int, html : Html Msg}
    pieceDiv pos display zlevel pid =
      let
        offset = pieceIdToOffset model.image pid
        tl = Point.add offset (Point.sub pos <| Point (pieceWidth/2) (pieceHeight/2))
        wh = Point (2 * pieceWidth) (2 * pieceHeight)
        html =
          Html.div
          [ Html.Attributes.style "z-index" <| zlevel
    --      , Html.Attributes.style "filter" <| "drop-shadow(0px 0px 2px " ++ color ++ ")"
          , Html.Attributes.style "position" "absolute"
          ]
          [
          Html.div
            [ Html.Attributes.style "position" "absolute"
            , Html.Attributes.style "width" <| Point.xToPixel wh
            , Html.Attributes.style "height" <| Point.yToPixel wh
            , Html.Attributes.style "top" <| Point.yToPixel tl
            , Html.Attributes.style "left" <| Point.xToPixel tl
            , Html.Attributes.style "z-index" <| zlevel
            , Html.Attributes.style "display" display
            ]
            [
              Html.canvas
              [ Html.Attributes.id <| "canvas-pid-" ++ String.fromInt pid
              , Html.Attributes.style "position" "absolute"
              , Html.Attributes.style "top" "0px"
              , Html.Attributes.style "left" "0px"
              , Html.Attributes.style "width" <| Point.xToPixel wh
              , Html.Attributes.style "height" <| Point.yToPixel wh
              ]
              []
            ]
          ]
      in
        {pid = pid, html = html}

    -- TODO: There must be a faster way to do this, right?
    -- Maybe just iterate over the pids, with a reference table for the corresponding PieceGroup?
    viewPieces : List (Html Msg)
    viewPieces =
      D.values model.pieceGroups
        |> List.concatMap viewPieceGroup
        |> List.sortBy .pid
        |> List.map (\{pid, html} -> html)

  in
    [ Html.div
      ( visibility ::
        turnOffTheBloodyImageDragging )
      ( viewPieces )
    ]


-- MENU

viewMenu : Model -> Html Msg
viewMenu model =
  Html.div
  [ Html.Attributes.style "width" "100%"
  , Html.Attributes.style "height" "50px"
  , Html.Attributes.style "position" "fixed"
  , Html.Attributes.style "top" "0"
  , Html.Attributes.style "left" "0px"
  , Html.Attributes.style "background-color" "#CCCCCC"
  , Html.Attributes.style "box-shadow" "-2px 5px 4px grey"
  , Html.Attributes.style "z-index" <| String.fromInt <| model.maxZLevel + 10
  , Html.Attributes.style "flex-direction" "column"
  ]
  [
    Html.div
    [ Html.Attributes.class "dropdown"
    ]
    [
      Html.button
      [ Html.Attributes.class "dropbtn"
      ]
      [ Html.text "Menu"
      ]
    , Html.div
      [ Html.Attributes.class "dropdown-content"
      ]
      [ Html.a
        [ Html.Events.onClick Scramble ]
        [ Html.text "Scramble" ]
      , Html.a
        [ Html.Events.onClick PickImage ]
        [ Html.text "Choose image" ]
      , Html.a
        [ Html.Events.onClick <| Cheat 1 ]
        [ Html.text "Cheat 1" ]
      , Html.a
        [ Html.Events.onClick <| Cheat 10 ]
        [ Html.text "Cheat 10" ]
      , Html.a
        [ Html.Events.onClick <| Cheat 100 ]
        [ Html.text "Cheat 100" ]
      , Html.a
        []
        [ Html.text "[TODO] Options" ]
      ]
    ]
  ]


-- PORTS
port drawPiecesInCanvas : JSMessage -> Cmd msg
port canvasDrawn : ((Int, Int) -> msg) -> Sub msg
