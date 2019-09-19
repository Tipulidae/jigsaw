module Main exposing (..)

import Browser
import Set as S
import Dict as D
import Array as A
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Json.Decode
import Svg exposing (Svg)
import Svg.Attributes
import Svg.Events
import Svg.Keyed
import Svg.Lazy exposing (lazy, lazy2, lazy3)
import Random
import Random.List

import Point exposing (Point)
import Util exposing (takeFirst)
import Edge exposing (EdgePoints, makeEdgePoints)

-- MAIN
main =
  Browser.element
    { init = init
    , update = update
    , view = view
    , subscriptions = \_ -> Sub.none
    }


-- MODEL

type Msg
  = MouseDown Int Point Keyboard
  | MouseMove Point
  | MouseUp
  | Scramble

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
  , debug : String
  , seed : Random.Seed
  , edgePoints : A.Array EdgePoints
  }

type alias JigsawImage =
  { path : String
  , width : Int
  , height : Int
  , xpieces : Int
  , ypieces : Int
  }

type alias PieceGroup =
  { id : Int
  , members : List Int
  , neighbours : S.Set Int
  , position : Point
  , isSelected : Bool
  , zlevel : Int
  }

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
  }


-- INIT

init : () -> ( Model, Cmd Msg )
init () =
  let
    image =
      { path = "../resources/kitten.png"
      , width = 533
      , height = 538
      , xpieces = 6
      , ypieces = 6
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
    numberOfEdges = 2 * nx * ny - nx - ny

    (positions, seed1) = shufflePiecePositions w h image seed
    (zlevels, seed2) = shuffleZLevels (nx * ny) seed1
    (edgePoints, seed3) = makeEdgePoints numberOfEdges seed2
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
    , debug = "Nothing to see here..."
    , seed = seed3
    , edgePoints = edgePoints
    }


shufflePiecePositions : Int -> Int -> JigsawImage -> Random.Seed -> (List Point, Random.Seed)
shufflePiecePositions w h image seed =
  let
    n = image.xpieces * image.ypieces
    xmin = 0
    xmax = w - image.width // image.xpieces
    ymin = 0
    ymax = h - image.height // image.ypieces
  in
    Random.step (Point.randomPoints n xmin xmax ymin ymax) seed

shuffleZLevels : Int -> Random.Seed -> (List Int, Random.Seed)
shuffleZLevels n seed =
  Random.step (Random.List.shuffle <| List.range 0 (n - 1)) seed

createPieceGroups : JigsawImage -> List Point -> List Int -> D.Dict Int PieceGroup
createPieceGroups image points levels =
  let
    nx = image.xpieces
    ny = image.ypieces
    n = nx*ny

    range =
      List.range 0 (n - 1)
    positions =
      if List.length points < n then
        List.map (pieceIdToOffset image) range
      else
        points
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
    onePieceGroup i pos zlevel =
      ( i
      , { position = Point.sub pos (pieceIdToOffset image i)
        , isSelected = False
        , id = i
        , zlevel = zlevel
        , members = [ i ]
        , neighbours = S.filter (isRealNeighbour i) <| S.fromList (possibleNeighbours i)
        }
      )

  in
    D.fromList <| List.map3 onePieceGroup range positions zlevels


pieceIdToPoint : Int -> Int -> Point
pieceIdToPoint id xpieces =
  Point (modBy xpieces id) (id // xpieces)

pieceIdToOffset : JigsawImage -> Int -> Point
pieceIdToOffset image id =
  let
    pieceWidth = image.width // image.xpieces
    pieceHeight = image.height // image.ypieces
  in
    Point.dot
      ( pieceIdToPoint id image.xpieces )
      ( Point pieceWidth pieceHeight )


isPieceInsideBox : JigsawImage -> Point -> Point -> Point -> Int -> Bool
isPieceInsideBox image pos boxTL boxBR id =
  let
    pieceWidth = image.width // image.xpieces
    pieceHeight = image.height // image.ypieces
    pieceTL = Point.add pos <| pieceIdToOffset image id
    pieceBR = Point.add pieceTL <| Point pieceWidth pieceHeight
  in
    ( pieceTL.x < boxBR.x ) &&
    ( pieceTL.y < boxBR.y ) &&
    ( pieceBR.x > boxTL.x ) &&
    ( pieceBR.y > boxTL.y )

isPieceGroupInsideBox : JigsawImage -> Point -> Point -> PieceGroup -> Bool
isPieceGroupInsideBox image boxTL boxBR pieceGroup =
  List.any (isPieceInsideBox image pieceGroup.position boxTL boxBR) pieceGroup.members

-- UPDATE

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
  case msg of
    Scramble ->
      let
        newModel = resetModel model.image model.seed
      in
        ( newModel, Cmd.none )

    MouseDown id coordinate keyboard ->
      let
        clickedOnBackground = id == -1
        newModel =
          if clickedOnBackground then
            startSelectionBox model coordinate keyboard
          else
            selectPieceGroup model id coordinate keyboard
      in
        ( newModel, Cmd.none )

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
                    originallySelected = S.member pg.id box.selectedIds
                    insideBoxNow = isPieceGroupInsideBox model.image tl br pg
                    newSelectionStatus =
                      if originallySelected && insideBoxNow then
                        True
                      else if originallySelected && not insideBoxNow then
                        True
                      else if not originallySelected && insideBoxNow then
                        True
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
                    originallySelected = S.member pg.id box.selectedIds
                    insideBoxNow = isPieceGroupInsideBox model.image tl br pg
                    newSelectionStatus =
                      if originallySelected && insideBoxNow then
                        False
                      else if originallySelected && not insideBoxNow then
                        True
                      else if not originallySelected && insideBoxNow then
                        True
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
    neighbourDistance : PieceGroup -> PieceGroup -> (Float, PieceGroup)
    neighbourDistance selectedPiece neighbour =
      ( Point.dist selectedPiece.position neighbour.position
      , neighbour)

    neighbourFromId : Int -> PieceGroup
    neighbourFromId id =
      Maybe.withDefault defaultPieceGroup
        <| D.get id model.pieceGroups

    distanceToSelected : List (Float, PieceGroup)
    distanceToSelected =
      List.map ((neighbourDistance selected) << neighbourFromId) (S.toList selected.neighbours)

    smallEnough : (Float, a) -> Bool
    smallEnough (distance, _) =
      distance < model.snapDistance

    closeNeighbour : Maybe PieceGroup
    closeNeighbour =
      case takeFirst smallEnough distanceToSelected of
        Nothing -> Nothing
        Just (_, neighbour) -> Just neighbour

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

-- VIEW

view : Model -> Html Msg
view model =
  let
    definitions =
      ( "definitions "
      , Svg.defs []
        ( lazy definePuzzleImage model.image :: definePieceClipPaths model.image model.edgePoints )
      )

    background =
      ( "background"
      , Svg.rect
        [ Svg.Attributes.width "100%"
        , Svg.Attributes.height "100%"
        , Svg.Attributes.fill "blue"
        , Svg.Attributes.opacity "0.0"
        , onMouseDown -1
        ]
        []
      )

    svgSelectionBox box color =
      let
        topLeft = boxTopLeft box
        bottomRight = boxBottomRight box
      in
        ( "selectionBox"
        , Svg.rect
          [ Svg.Attributes.width <| String.fromInt (bottomRight.x - topLeft.x)
          , Svg.Attributes.height <| String.fromInt (bottomRight.y - topLeft.y)
          , Svg.Attributes.fill color
          , Svg.Attributes.fillOpacity "0.2"
          , Svg.Attributes.stroke <| "dark"++color
          , Svg.Attributes.strokeWidth "2px"
          , Svg.Attributes.strokeOpacity "0.9"
          , translate (topLeft)
          ]
          []
        )

    normalSelection =
      case model.selectionBox of
        Normal box ->
          [ svgSelectionBox box "blue" ]
        Inverted box ->
          [ svgSelectionBox box "green" ]
        NullBox -> []

    pieces =
      List.concat
        <| List.map svgPieceGroup
        <| List.sortBy .zlevel
        <| D.values model.pieceGroups

    svgPieceGroup pg =
      List.map (svgMember pg.id pg.position pg.isSelected) pg.members

    svgMember groupId pos selected id =
      ( "group-" ++ String.fromInt groupId
      , Svg.g
        [ onMouseDown groupId, translate pos ]
        ([lazy svgClipPath id] ++ [lazy2 svgOutlines selected id])
      )

    svgClipPath id =
      Svg.use
        [ Svg.Attributes.xlinkHref <| "#puzzle-image"
        , Svg.Attributes.clipPath <| clipPathRef id
        ]
        []

    svgOutlines selected id =
      Svg.use
        [ Svg.Attributes.xlinkHref <| "#" ++ pieceOutlineId id
        , Svg.Attributes.stroke <| if selected then "red" else "black"
        , Svg.Attributes.strokeWidth "5px"
        ]
        []

    pieceGroupDiv pg =
      List.map (pieceDiv pg.position pg.id) pg.members

    pieceDiv pos pgid pid =
      let
        offset = pieceIdToOffset model.image pid
        w = 2 * model.image.width // model.image.xpieces
        h = 2 * model.image.height // model.image.ypieces
        top = String.fromInt (pos.y + offset.y - h//4) ++ "px"
        left = String.fromInt (pos.x + offset.x - w//4) ++ "px"
      in
      Html.div
--        [ Html.Attributes.style "background-color" "#FF0000"
        [
          Html.Attributes.style "background" "transparent"
        , Html.Attributes.style "width" <| String.fromInt w ++ "px"
        , Html.Attributes.style "height" <| String.fromInt h ++ "px"
        , Html.Attributes.style "position" "absolute"
        , Html.Attributes.style "top" top
        , Html.Attributes.style "left" left
--        , Html.Attributes.style "z-index" "10"
--        , Html.Attributes.style "clipPath" "url(#mypath)"
        ]
        [
          Svg.svg
          [ Svg.Attributes.width "100%"
          , Svg.Attributes.height "100%"
          , Svg.Attributes.viewBox <| String.fromInt (offset.x - w//4) ++ " " ++ String.fromInt (offset.y - h//4) ++ " " ++ Point.toString (Point w h)
          , onMouseDown pgid
          ]
          [ Svg.use
            [ Svg.Attributes.xlinkHref "#puzzle-image"
            , Svg.Attributes.clipPath <| clipPathRef pid
            ]
            []
          ]
        ]

  in
  Html.div [ ]
    [ Html.button [ Html.Events.onClick Scramble ] [ Html.text "scramble" ]
--    , Html.h1 [] [ Html.text model.debug ]
--    , Html.div
--        [ Html.Attributes.style "background-color" "#CCCCCC"
--        , Html.Attributes.style "width" <| String.fromInt model.width ++ "px"
--        , Html.Attributes.style "height" <| String.fromInt model.height ++ "px"
--        ]
--        [ Svg.Keyed.node "svg"
--          ( svgAttributes model )
--          ( definitions :: background :: pieces ++ normalSelection)
--        ]
    , Html.div
      [ Html.Attributes.style "background-color" "#CCCCCC"
      , Html.Attributes.style "width" "1000px"
      , Html.Attributes.style "height" "500px"
      , Html.Attributes.style "position" "absolute"
      , Html.Attributes.style "top" "100px"
      ]
      (
      [
        Svg.svg
        []
        [ Svg.defs []
          (definePuzzleImage model.image :: definePieceClipPaths model.image model.edgePoints)
        ]
--        [
--          Html.div
--          [ Html.Attributes.style "background-color" "#FF0000"
--          , Html.Attributes.style "width" <| "100px"
--          , Html.Attributes.style "height" <| "100px"
--          , Html.Attributes.style "position" "absolute"
--          , Html.Attributes.style "top" <| "100px"
--          , Html.Attributes.style "left" <| "100px"
--          , Html.Attributes.style "z-index" "10"
--          ]
--          []
--        ]
      ] ++ (List.concat <| List.map pieceGroupDiv <| D.values model.pieceGroups))
    ]


svgAttributes model =
  let
    attributes =
      [ Svg.Attributes.width "100%"
      , Svg.Attributes.height "100%"
      ]
    shouldTrackMouseMovement =
      model.cursor /=  Nothing
  in
  if shouldTrackMouseMovement then
    onMouseMove :: onMouseUp :: attributes
  else
    attributes

onMouseUp : Svg.Attribute Msg
onMouseUp =
  Svg.Events.onMouseUp MouseUp

onMouseDown : Int -> Svg.Attribute Msg
onMouseDown id =
  Svg.Events.on "mousedown"
    <| Json.Decode.map4 (\x y shift ctrl -> MouseDown id (Point x y) {shift=shift, ctrl=ctrl})
      (Json.Decode.field "offsetX" Json.Decode.int)
      (Json.Decode.field "offsetY" Json.Decode.int)
      (Json.Decode.field "shiftKey" Json.Decode.bool)
      (Json.Decode.field "ctrlKey" Json.Decode.bool)

onMouseMove : Svg.Attribute Msg
onMouseMove =
  Svg.Events.on "mousemove"
    <| Json.Decode.map2 (\x y -> MouseMove (Point x y))
      (Json.Decode.field "offsetX" Json.Decode.int)
      (Json.Decode.field "offsetY" Json.Decode.int)

translate : Point -> Svg.Attribute Msg
translate position =
  Svg.Attributes.transform
    <| "translate(" ++ String.fromInt position.x ++ "," ++ String.fromInt position.y ++ ")"


definePuzzleImage : JigsawImage -> Svg Msg
definePuzzleImage image =
  Svg.image
    [ Svg.Attributes.id "puzzle-image"
    , Svg.Attributes.xlinkHref image.path
    , Svg.Attributes.pointerEvents "none"
    ]
    []


definePieceClipPaths : JigsawImage -> A.Array EdgePoints -> List (Svg Msg)
definePieceClipPaths image edgePoints =
  List.map (lazy3 pieceClipPath image edgePoints) (List.range 0 (image.xpieces * image.ypieces - 1))

pieceClipPath : JigsawImage -> A.Array EdgePoints -> Int -> Svg Msg
pieceClipPath image edgePoints id =
  let
    w = toFloat (image.width // image.xpieces)
    h = toFloat (image.height // image.ypieces)
    offset = pieceIdToOffset image id

    curve = Edge.pieceCurveFromPieceId image.xpieces image.ypieces id edgePoints
    move = "translate(" ++ Point.toString offset ++ ") "
    scale = "scale(" ++ String.fromFloat (w / 200.0) ++ " " ++ String.fromFloat (h / 200.0) ++ ")"
  in
    Svg.clipPath
      [ Svg.Attributes.id <| pieceClipId id ]
      [ Svg.path
        [ Svg.Attributes.id <| pieceOutlineId id
        , Svg.Attributes.transform <| move ++ scale
        , Svg.Attributes.d curve
        , Svg.Attributes.fillOpacity "0.0"
        ]
        []
      ]

pieceOutlineId : Int -> String
pieceOutlineId id =
  "piece-" ++ String.fromInt id ++ "-outline"

pieceClipId : Int -> String
pieceClipId id =
  "piece-" ++ String.fromInt id ++ "-clip"

clipPathRef : Int -> String
clipPathRef id =
  "url(#" ++ pieceClipId id ++ ")"

