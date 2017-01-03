module Array.Hamt
    exposing
        ( Array
        , empty
        , isEmpty
        , length
        , initialize
        , repeat
        , fromList
        , get
        , set
        , push
        , toList
        , toIndexedList
        , foldr
        , foldl
        , filter
        , map
        , indexedMap
        , append
        , slice
        , toString
        )

{-| Fast immutable arrays. The elements in an array must have the same type.

# Arrays
@docs Array

# Creation
@docs empty, initialize, repeat, fromList

# Query
@docs isEmpty, length, get

# Manipulate
@docs set, push, append, slice

# Lists
@docs toList, toIndexedList

# Transform
@docs foldl, foldr, filter, map, indexedMap

# Display
@docs toString
-}

import Bitwise
import Array.JsArray as JsArray exposing (JsArray)


{-| The array in this module is implemented as a tree with a high branching
factor (number of elements at each level). In comparision, the `Dict` has
a branching factor of 2 (left or right).

The higher the branching factor, the more elements are stored at each level.
This makes writes slower (more to copy per level), but reads faster
(fewer traversals). In practice, 32 is a good compromise.

The branching factor has to be a power of two (8, 16, 32, 64...). This is
because we use the index to tell us which path to take when navigating the
tree, and we do this by dividing it into several smaller numbers (see
`shiftStep` documentation). By dividing the index into smaller numbers, we
will always get a range which is a power of two (2 bits gives 0-3, 3 gives
0-7, 4 gives 0-15...).
-}
branchFactor : Int
branchFactor =
    32


{-| A number is made up of several bits. For bitwise operations in javascript,
numbers are treated as 32-bits integers. The number 1 is represented by 31
zeros, and a one. The important thing to take from this, is that a 32-bit
integer has enough information to represent several smaller numbers.

For a branching factor of 32, a 32-bit index has enough information to store 6
different numbers in the range of 0-31 (5 bits), and one number in the range of
0-3 (2 bits). This means that the tree of an array can have, at most, a depth
of 7.

An index essentially functions as a map. To figure out which branch to take at
any given level of the tree, we need to shift (or move) the correct amount of
bits so that those bits are at the front. We can then perform a bitwise and to
read which of the 32 branches to take.

The `shiftStep` specifices how many bits are required to represent the branching
factor.
-}
shiftStep : Int
shiftStep =
    logBase 2 (toFloat branchFactor) |> ceiling


{-| A mask which, when used in a bitwise and, reads the first `shiftStep` bits
in a number as a number of its own.
-}
bitMask : Int
bitMask =
    Bitwise.shiftRightZfBy (32 - shiftStep) 0xFFFFFFFF


{-| Representation of fast immutable arrays. You can create arrays of integers
(`Array Int`) or strings (`Array String`) or any other type of value you can
dream up.
-}
type Array a
    = {-
         * length : Int = The length of the array.
         * startShift : Int = How many bits to shift the index to get the
         slot for the first level of the tree.
         * tree : Tree a = The actual tree.
         * tail : JsArray a = The tail of the array. Inserted into tree when
         number of elements is equal to the branching factor. This is an
         optimization. It makes operations at the end (push, pop, read, write)
         fast.
      -}
      Array Int Int (Tree a) (JsArray a)


{-| Each level in the tree is represented by a `JsArray` of `Node`s.
A `Node` can either be a subtree (the next level of the tree) or, if
we're at the bottom, a `JsArray` of values (also known as a leaf).
-}
type Node a
    = SubTree (Tree a)
    | Leaf (JsArray a)


type alias Tree a =
    JsArray (Node a)


{-| Return an empty array.

    length empty == 0
-}
empty : Array a
empty =
    {-
       `startShift` is only used when there is at least one `Node` in the
       `tree`. The minimal value is therefore equal to the `shiftStep`.
    -}
    Array 0 shiftStep JsArray.empty JsArray.empty


{-| Determine if an array is empty.

    isEmpty empty == True
-}
isEmpty : Array a -> Bool
isEmpty (Array length _ _ _) =
    length == 0


{-| Return the length of an array.

    length (fromList [1,2,3]) == 3
-}
length : Array a -> Int
length (Array length _ _ _) =
    length


{-| Initialize an array. `initialize n f` creates an array of length `n` with
the element at index `i` initialized to the result of `(f i)`.

    initialize 4 identity    == fromList [0,1,2,3]
    initialize 4 (\n -> n*n) == fromList [0,1,4,9]
    initialize 4 (always 0)  == fromList [0,0,0,0]
-}
initialize : Int -> (Int -> a) -> Array a
initialize length fn =
    if length <= 0 then
        empty
    else
        initializeHelp 0 length length fn []


initializeHelp : Int -> Int -> Int -> (Int -> a) -> List (Node a) -> Array a
initializeHelp fromIndex toIndex length fn nodeList =
    let
        nodeSize =
            min branchFactor (toIndex - fromIndex)

        node =
            JsArray.initialize nodeSize fromIndex fn
    in
        if nodeSize < branchFactor then
            builderToArray
                { tail = node
                , nodeList = nodeList
                , nodeListSize = length // branchFactor
                }
        else
            initializeHelp
                (fromIndex + nodeSize)
                toIndex
                length
                fn
                ((Leaf node) :: nodeList)


{-| Creates an array with a given length, filled with a default element.

    repeat 5 0     == fromList [0,0,0,0,0]
    repeat 3 "cat" == fromList ["cat","cat","cat"]

Notice that `repeat 3 x` is the same as `initialize 3 (always x)`.
-}
repeat : Int -> a -> Array a
repeat n e =
    initialize n (\_ -> e)


{-| Create an array from a `List`.
-}
fromList : List a -> Array a
fromList ls =
    case ls of
        [] ->
            empty

        _ ->
            fromListHelp ls [] 0


fromListHelp : List a -> List (Node a) -> Int -> Array a
fromListHelp list nodeList nodeListSize =
    let
        ( remainingItems, jsArray ) =
            JsArray.listInitialize list branchFactor
    in
        if JsArray.length jsArray < branchFactor then
            builderToArray
                { tail = jsArray
                , nodeList = nodeList
                , nodeListSize = nodeListSize
                }
        else
            fromListHelp
                remainingItems
                ((Leaf jsArray) :: nodeList)
                (nodeListSize + 1)


{-| Return the array represented as a string.

    (toString <| Array.fromList [1,2,3]) == "Array [1,2,3]"
-}
toString : Array a -> String
toString array =
    let
        elements =
            array
                |> map Basics.toString
                |> toList
                |> String.join ","
    in
        "Array [" ++ elements ++ "]"


{-| Return `Just` the element at the index or `Nothing`` if the index is out of
range.

    get  0 (fromList [0,1,2]) == Just 0
    get  2 (fromList [0,1,2]) == Just 2
    get  5 (fromList [0,1,2]) == Nothing
    get -1 (fromList [0,1,2]) == Nothing
-}
get : Int -> Array a -> Maybe a
get idx (Array length startShift tree tail) =
    if idx < 0 || idx >= length then
        Nothing
    else if idx >= tailIndex length then
        Just <| JsArray.unsafeGet (Bitwise.and bitMask idx) tail
    else
        Just <| getHelp startShift idx tree


getHelp : Int -> Int -> Tree a -> a
getHelp shift idx tree =
    let
        pos =
            Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift idx
    in
        case JsArray.unsafeGet pos tree of
            SubTree subTree ->
                getHelp (shift - shiftStep) idx subTree

            Leaf values ->
                JsArray.unsafeGet (Bitwise.and bitMask idx) values


{-| Given an array length, return the index of the first element in the tail.
Used to check if a given index references something in the tail.
-}
tailIndex : Int -> Int
tailIndex len =
    len
        |> Bitwise.shiftRightZfBy 5
        |> Bitwise.shiftLeftBy 5


{-| Set the element at a particular index. Returns an updated array.
If the index is out of range, the array is unaltered.

    set 1 7 (fromList [1,2,3]) == fromList [1,7,3]
-}
set : Int -> a -> Array a -> Array a
set idx val ((Array length startShift tree tail) as arr) =
    if idx < 0 || idx >= length then
        arr
    else if idx >= tailIndex length then
        Array length startShift tree <|
            JsArray.unsafeSet (Bitwise.and bitMask idx) val tail
    else
        Array
            length
            startShift
            (setHelp startShift idx val tree)
            tail


setHelp : Int -> Int -> a -> Tree a -> Tree a
setHelp shift idx val tree =
    let
        pos =
            Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift idx
    in
        case JsArray.unsafeGet pos tree of
            SubTree subTree ->
                let
                    newSub =
                        setHelp (shift - shiftStep) idx val subTree
                in
                    JsArray.unsafeSet pos (SubTree newSub) tree

            Leaf values ->
                let
                    newLeaf =
                        JsArray.unsafeSet (Bitwise.and bitMask idx) val values
                in
                    JsArray.unsafeSet pos (Leaf newLeaf) tree


{-| Push an element onto the end of an array.

    push 3 (fromList [1,2]) == fromList [1,2,3]
-}
push : a -> Array a -> Array a
push a (Array length startShift tree tail) =
    let
        modifiedTail =
            JsArray.push a tail

        tailLen =
            JsArray.length modifiedTail

        newLen =
            length + 1

        overflow =
            Bitwise.shiftRightZfBy shiftStep newLen >= Bitwise.shiftLeftBy startShift 1

        newTree =
            if tailLen == branchFactor then
                pushTailHelp startShift length newTail tree
            else
                tree

        newTail =
            if tailLen == branchFactor then
                JsArray.empty
            else
                modifiedTail
    in
        if overflow then
            Array
                newLen
                (startShift + shiftStep)
                (JsArray.singleton (SubTree newTree))
                newTail
        else
            Array
                newLen
                startShift
                newTree
                newTail


pushTailHelp : Int -> Int -> JsArray a -> Tree a -> Tree a
pushTailHelp shift idx tail tree =
    let
        pos =
            Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift idx
    in
        if pos >= JsArray.length tree then
            if shift == 5 then
                JsArray.push (Leaf tail) tree
            else
                let
                    newSub =
                        JsArray.empty
                            |> pushTailHelp (shift - shiftStep) idx tail
                            |> SubTree
                in
                    JsArray.push newSub tree
        else
            let
                val =
                    JsArray.unsafeGet pos tree
            in
                case val of
                    SubTree subTree ->
                        let
                            newSub =
                                subTree
                                    |> pushTailHelp (shift - shiftStep) idx tail
                                    |> SubTree
                        in
                            JsArray.unsafeSet pos newSub tree

                    Leaf _ ->
                        let
                            newSub =
                                JsArray.singleton val
                                    |> pushTailHelp (shift - shiftStep) idx tail
                                    |> SubTree
                        in
                            JsArray.unsafeSet pos newSub tree


{-| Create a list of elements from an array.

    toList (fromList [3,5,8]) == [3,5,8]
-}
toList : Array a -> List a
toList arr =
    foldr (::) [] arr


{-| Create an indexed list from an array. Each element of the array will be
paired with its index.

    toIndexedList (fromList ["cat","dog"]) == [(0,"cat"), (1,"dog")]
-}
toIndexedList : Array a -> List ( Int, a )
toIndexedList ((Array length _ _ _) as arr) =
    let
        helper n ( idx, ls ) =
            ( idx - 1, ( idx, n ) :: ls )
    in
        Tuple.second <| foldr helper ( length - 1, [] ) arr


{-| Reduce an array from the right. Read `foldr` as fold from the right.

    foldr (+) 0 (repeat 3 5) == 15
-}
foldr : (a -> b -> b) -> b -> Array a -> b
foldr f init (Array _ _ tree tail) =
    let
        helper i acc =
            case i of
                SubTree subTree ->
                    JsArray.foldr helper acc subTree

                Leaf values ->
                    JsArray.foldr f acc values

        acc =
            JsArray.foldr f init tail
    in
        JsArray.foldr helper acc tree


{-| Reduce an array from the left. Read `foldl` as fold from the left.

    foldl (::) [] (fromList [1,2,3]) == [3,2,1]
-}
foldl : (a -> b -> b) -> b -> Array a -> b
foldl f init (Array _ _ tree tail) =
    let
        helper i acc =
            case i of
                SubTree subTree ->
                    JsArray.foldl helper acc subTree

                Leaf values ->
                    JsArray.foldl f acc values

        acc =
            JsArray.foldl helper init tree
    in
        JsArray.foldl f acc tail


{-| Keep only elements that satisfy the predicate.

    filter isEven (fromList [1,2,3]) == (fromList [2])
-}
filter : (a -> Bool) -> Array a -> Array a
filter f arr =
    let
        helper n acc =
            if f n then
                n :: acc
            else
                acc
    in
        foldr helper [] arr
            |> fromList


{-| Apply a function on every element in an array.

    map sqrt (fromList [1,4,9]) == fromList [1,2,3]
-}
map : (a -> b) -> Array a -> Array b
map f (Array length startShift tree tail) =
    let
        helper i =
            case i of
                SubTree subTree ->
                    SubTree <| JsArray.map helper subTree

                Leaf values ->
                    Leaf <| JsArray.map f values
    in
        Array
            length
            startShift
            (JsArray.map helper tree)
            (JsArray.map f tail)


{-| Apply a function on every element with its index as first argument.

    indexedMap (*) (fromList [5,5,5]) == fromList [0,5,10]
-}
indexedMap : (Int -> a -> b) -> Array a -> Array b
indexedMap f ((Array length _ tree tail) as arr) =
    let
        helper node builder =
            case node of
                SubTree subTree ->
                    JsArray.foldl helper builder subTree

                Leaf leaf ->
                    let
                        offset =
                            builder.nodeListSize * branchFactor

                        mappedLeaf =
                            Leaf <| JsArray.indexedMap f offset leaf
                    in
                        { tail = builder.tail
                        , nodeList = mappedLeaf :: builder.nodeList
                        , nodeListSize = builder.nodeListSize + 1
                        }

        initialBuilder =
            { tail = JsArray.indexedMap f (tailIndex length) tail
            , nodeList = []
            , nodeListSize = 0
            }
    in
        JsArray.foldl helper initialBuilder tree
            |> builderToArray


{-| Append one array onto another one.

    append (repeat 2 42) (repeat 3 81) == fromList [42,42,81,81,81]
-}
append : Array a -> Array a -> Array a
append a (Array _ _ bTree bTail) =
    let
        builder =
            builderFromArray a

        foldHelper node builder =
            case node of
                SubTree tree ->
                    JsArray.foldl foldHelper builder tree

                Leaf leaf ->
                    appendHelp leaf builder
    in
        JsArray.foldl foldHelper builder bTree
            |> appendHelp bTail
            |> builderToArray


appendHelp : JsArray a -> Builder a -> Builder a
appendHelp tail builder =
    let
        merged =
            JsArray.merge builder.tail tail branchFactor

        mergedLen =
            JsArray.length merged

        tailLen =
            JsArray.length tail

        leftOver =
            max 0 <| (JsArray.length builder.tail) + tailLen - branchFactor
    in
        if mergedLen == branchFactor then
            { tail = JsArray.slice (tailLen - leftOver) tailLen tail
            , nodeList = (Leaf merged) :: builder.nodeList
            , nodeListSize = builder.nodeListSize + 1
            }
        else
            { tail = merged
            , nodeList = builder.nodeList
            , nodeListSize = builder.nodeListSize
            }


{-| Get a sub-section of an array: `(slice start end array)`. The `start` is a
zero-based index where we will start our slice. The `end` is a zero-based index
that indicates the end of the slice. The slice extracts up to but not including
`end`.

    slice  0  3 (fromList [0,1,2,3,4]) == fromList [0,1,2]
    slice  1  4 (fromList [0,1,2,3,4]) == fromList [1,2,3]

Both the `start` and `end` indexes can be negative, indicating an offset from
the end of the array.

    slice  1 -1 (fromList [0,1,2,3,4]) == fromList [1,2,3]
    slice -2  5 (fromList [0,1,2,3,4]) == fromList [3,4]

This makes it pretty easy to `pop` the last element off of an array:
`slice 0 -1 array`
-}
slice : Int -> Int -> Array a -> Array a
slice from to arr =
    let
        correctFrom =
            translateIndex from arr

        correctTo =
            translateIndex to arr
    in
        if correctFrom > correctTo then
            empty
        else
            arr
                |> sliceRight correctTo
                |> sliceLeft correctFrom


{-| Given a relative array index, convert it into an absolute one.

    translateIndex -1 someArray == someArray.length - 1
    translateIndex -10 someArray == someArray.length - 10
    translateIndex 5 someArray == 5
-}
translateIndex : Int -> Array a -> Int
translateIndex idx (Array length _ _ _) =
    let
        posIndex =
            if idx < 0 then
                length + idx
            else
                idx
    in
        if posIndex < 0 then
            0
        else if posIndex > length then
            length
        else
            posIndex


{-| This function slices the tree from the right.

First, two things are tested:
1. If the array does not need slicing, return the original array.
2. If the array can be sliced by only slicing the tail, slice the tail.

Otherwise, we do the following:
1. Find the new tail in the tree, promote it to the root tail position and
slice it.
2. Slice every sub tree.
3. Promote subTrees until the tree has the correct height.
-}
sliceRight : Int -> Array a -> Array a
sliceRight end ((Array length startShift tree tail) as arr) =
    if end == length then
        arr
    else if end >= tailIndex length then
        Array end startShift tree <|
            JsArray.slice 0 (Bitwise.and bitMask end) tail
    else
        let
            endIdx =
                tailIndex end

            depth =
                end
                    |> toFloat
                    |> logBase (toFloat branchFactor)
                    |> floor

            newShift =
                depth * shiftStep
        in
            Array
                end
                newShift
                (tree
                    |> sliceTree startShift endIdx
                    |> hoistTree startShift newShift
                )
                (fetchNewTail startShift end endIdx tree)


{-| Slice and return the `Leaf` node after what is to be the last node
in the sliced tree.
-}
fetchNewTail : Int -> Int -> Int -> Tree a -> JsArray a
fetchNewTail shift end treeEnd tree =
    let
        pos =
            Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift treeEnd
    in
        case JsArray.unsafeGet pos tree of
            SubTree sub ->
                fetchNewTail (shift - shiftStep) end treeEnd sub

            Leaf values ->
                JsArray.slice 0 (Bitwise.and bitMask end) values


{-| Shorten the root `Node` of the tree so it is long enough to contain
the `Node` indicated by `endIdx`. Then recursively perform the same operation
to the last node of each `SubTree`.
-}
sliceTree : Int -> Int -> Tree a -> Tree a
sliceTree shift endIdx tree =
    let
        lastPos =
            Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift endIdx
    in
        case JsArray.unsafeGet lastPos tree of
            SubTree sub ->
                let
                    newSub =
                        sliceTree (shift - shiftStep) endIdx sub
                in
                    -- The sub is empty, slice it away
                    if JsArray.length newSub == 0 then
                        JsArray.slice 0 lastPos tree
                    else
                        tree
                            |> JsArray.slice 0 (lastPos + 1)
                            |> JsArray.unsafeSet lastPos (SubTree newSub)

            -- This is supposed to be the new tail. Fetched by fetchNewtail.
            --Slice up to, but not including, this point.
            Leaf _ ->
                JsArray.slice 0 lastPos tree


{-| The tree is supposed to be of a certain depth. Since slicing removes
elements from the tree, it could be that the tree should have a smaller depth
than it had originally. This function shortens the height if it is necessary
to do so.
-}
hoistTree : Int -> Int -> Tree a -> Tree a
hoistTree oldShift newShift tree =
    if oldShift <= newShift then
        tree
    else
        case JsArray.unsafeGet 0 tree of
            SubTree sub ->
                hoistTree (oldShift - shiftStep) newShift sub

            Leaf _ ->
                tree


{-| This function slices the tree from the left. Such an operation will change
the index of every element after the slice. Which means that we will have to
rebuild the array.

First, two things are tested:
1. If the array does not need slicing, return the original array.
2. If the slice removes every element but those in the tail, slice the tail and
set the tree to the empty array.

Otherwise, we do the following:
1. Add every leaf node in the three to a list.
2. Drop the nodes which are supposed to be sliced away.
3. Slice the head node of the list, which represents the start of the new array.
4. Create a builder with the tail set as the node from the previous step.
5. Append the remaining nodes into this builder, and create the array.
-}
sliceLeft : Int -> Array a -> Array a
sliceLeft from ((Array length _ tree tail) as arr) =
    if from == 0 then
        arr
    else if from >= tailIndex length then
        Array (length - from) shiftStep JsArray.empty <|
            JsArray.slice from (JsArray.length tail) tail
    else
        let
            helper node acc =
                case node of
                    SubTree subTree ->
                        JsArray.foldr helper acc subTree

                    Leaf leaf ->
                        leaf :: acc

            leafNodes =
                JsArray.foldr helper [ tail ] tree

            skipNodes =
                from // branchFactor

            nodesToInsert =
                List.drop skipNodes leafNodes
        in
            case nodesToInsert of
                [] ->
                    empty

                head :: rest ->
                    let
                        firstSlice =
                            from - (skipNodes * branchFactor)

                        initialBuilder =
                            { tail =
                                JsArray.slice
                                    firstSlice
                                    (JsArray.length head)
                                    head
                            , nodeList = []
                            , nodeListSize = 0
                            }
                    in
                        List.foldl appendHelp initialBuilder rest
                            |> builderToArray


{-| A builder contains all information necessary to build an array. Adding
information to the builder is fast. A builder is therefore a suitable
intermediary for constructing arrays.

Due to the nature of lists, we expect `nodeList` to be in reverse order. That
is, the first `Node` in the tree of an `Array`, should be last in the
`nodeList`.
-}
type alias Builder a =
    { tail : JsArray a
    , nodeList : List (Node a)
    , nodeListSize : Int
    }


{-| The empty builder.
-}
emptyBuilder : Builder a
emptyBuilder =
    { tail = JsArray.empty
    , nodeList = []
    , nodeListSize = 0
    }


{-| Converts an array to a builder.
-}
builderFromArray : Array a -> Builder a
builderFromArray (Array length _ tree tail) =
    let
        helper node acc =
            case node of
                SubTree tree ->
                    JsArray.foldl helper acc tree

                Leaf _ ->
                    node :: acc
    in
        { tail = tail
        , nodeList = JsArray.foldl helper [] tree
        , nodeListSize = length // branchFactor
        }


{-| Construct an array with the information in a given builder.
-}
builderToArray : Builder a -> Array a
builderToArray builder =
    if builder.nodeListSize == 0 then
        Array
            (JsArray.length builder.tail)
            shiftStep
            JsArray.empty
            builder.tail
    else
        let
            treeLen =
                builder.nodeListSize * branchFactor

            depth =
                treeLen
                    |> toFloat
                    |> logBase (toFloat branchFactor)
                    |> floor

            tree =
                treeFromBuilder
                    (List.reverse builder.nodeList)
                    builder.nodeListSize
        in
            Array
                (JsArray.length builder.tail + treeLen)
                (depth * shiftStep)
                (ensureTreeDepth depth tree)
                builder.tail


{-| Takes a list of leaves and an `Int` specifying how many leaves there are,
and builds a tree structure to be used in an `Array`.
-}
treeFromBuilder : List (Node a) -> Int -> Tree a
treeFromBuilder nodeList nodeListSize =
    let
        newNodeSize =
            ((toFloat nodeListSize) / (toFloat branchFactor))
                |> ceiling
    in
        if newNodeSize == 1 then
            JsArray.listInitialize nodeList branchFactor
                |> Tuple.second
        else
            treeFromBuilder
                (compressNodes nodeList [])
                newNodeSize


{-| Takes a list of nodes and return a list of `SubTree`s containing those
nodes.
-}
compressNodes : List (Node a) -> List (Node a) -> List (Node a)
compressNodes nodes acc =
    let
        ( newNodes, jsArray ) =
            JsArray.listInitialize nodes branchFactor

        newAcc =
            (SubTree jsArray) :: acc
    in
        case newNodes of
            [] ->
                List.reverse newAcc

            _ ->
                compressNodes newNodes newAcc


{-| When constructing an array from a builder, it is possible for the resulting
array to have a smaller depth than required. This has to do with how we
calculate the required depth. If you have 1024 elements in the tree, this can
fit within two levels, but our method of calculation says we require three.
This function corrects the few cases were this goes wrong.

TODO: Might be worth looking into how we can avoid the need for this function.
It will likely make no difference to performance, but a smaller implementation
is a good thing.
-}
ensureTreeDepth : Int -> Tree a -> Tree a
ensureTreeDepth requestedDepth tree =
    let
        depthMeasure acc tree =
            case JsArray.unsafeGet 0 tree of
                SubTree sub ->
                    depthMeasure (acc + 1) sub

                Leaf _ ->
                    acc

        actualDepth =
            depthMeasure 1 tree
    in
        if actualDepth == requestedDepth then
            tree
        else
            JsArray.singleton (SubTree tree)
