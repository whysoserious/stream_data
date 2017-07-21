defmodule StreamData do
  @moduledoc """
  Functions to create and combine generators.

  A generator is a `StreamData` struct. Generators can be created through the
  functions exposed in this module, like `constant/1`, and by combining other
  generators through functions like `bind/2`.

  ## Enumerable

  # TODO: The reader checking those docs for the first time I have no idea
  # what "unshrinkable values" below means.
  # Maybe we should write a small paragraph about when and how generators are
  # used, i.e. generating test data and property testing. In property testing,
  # we can talk about the importance of shrinking.

  Generators implement the `Enumerable` protocol. The implementation yields
  unshrinkable values when enumerating a generator. The enumeration starts with
  a small generation size, which increases when the enumeration continues (up to
  a fixed maximum size).

  For example, to get an infinite stream of integers that starts with small
  integers and progressively grows the boundaries, you can just use `int/0`:

      Enum.take(StreamData.int(), 10)
      #=> [-1, 0, -3, 4, -4, 5, -1, -3, 5, 8]

  Since generators are proper streams, functions from the `Stream` module can be
  used to stream values out of them. For example, to build an infinite stream of
  positive even integers, you can do:

      StreamData.int()
      |> Stream.filter(&(&1 > 0))
      |> Stream.map(&(&1 * 2))
      |> Enum.take(10)
      #=> [4, 6, 4, 10, 14, 16, 4, 16, 36, 16]

  # TODO: From the example above it seems generators do not emit uniq items.
  # Maybe that should be explicitly said.

  Note that all generators are **infinite** streams that never terminate.
  """

  alias StreamData.{
    LazyTree,
    Random,
  }

  @typep size :: non_neg_integer
  @typep generator_fun(a) :: (Random.seed, size -> LazyTree.t(a))

  @typedoc """
  An opaque type that represents a `StreamData` generator that generates values
  of type `a`.

  Note that while this type is opaque, a generator is still guaranteed to be a
  `StreamData` struct (in case you want to pattern match on it).
  """
  @opaque t(a) :: %__MODULE__{
    generator: generator_fun(a),
  }

  defstruct [:generator]

  defmodule FilterTooNarrowError do
    defexception [:message]

    # FIX: A good error message says what went wrong, why it went wrong
    # and possibly what can be done to fix it.
    def exception(options) do
      %__MODULE__{message: "too many failures: #{inspect(options)}"}
    end
  end

  defmodule TooManyDuplicatesError do
    defexception [:message]

    # FIX: A good error message says what went wrong, why it went wrong
    # and possibly what can be done to fix it.
    def exception(options) do
      %__MODULE__{message: "too many duplicates: #{inspect(options)}"}
    end
  end

  # TODO: All of the docs tells what happens on shrinking
  # *before* it shows examples. I would reverse that. I am
  # not interested on shrinking before I learn what the function
  # does and how it works.

  ### Minimal interface

  ## Helpers

  # QUESTION: Should we underscore those? We typically avoid
  # such functions in STDLIB modules because import StreamData
  # would bring them in. Alternatively we can make them public.

  @doc false
  @spec new(generator_fun(a)) :: t(a) when a: term
  def new(generator) when is_function(generator, 2) do
    %__MODULE__{generator: generator}
  end

  @doc false
  @spec call(t(a), Random.seed, non_neg_integer) :: a when a: term
  def call(%__MODULE__{generator: generator}, seed, size) do
    %LazyTree{} = generator.(seed, size)
  end

  ## Generators

  @doc """
  A generator that always generates the given term.

  ## Shrinking

  This generator doesn't shrink.

  ## Examples

      iex> Enum.take(StreamData.constant(:some_term), 3)
      [:some_term, :some_term, :some_term]

  """
  @spec constant(a) :: t(a) when a: var
  def constant(term) do
    new(fn _seed, _size -> LazyTree.constant(term) end)
  end

  ## Combinators

  @doc """
  Maps the given function `fun` over the given generator `data`.

  Returns a new generator that returns elements from `data` after applying `fun`
  to them.

  ## Shrinking

  This generator shrinks exactly like `data`, but with `fun` mapped over the
  shrinked data.

  ## Examples

      iex> data = StreamData.map(StreamData.int(), &Integer.to_string/1)
      iex> Enum.take(data, 3)
      ["1", "0", "3"]

  """
  @spec map(t(a), (a -> b)) :: t(b) when a: term, b: term
  def map(%__MODULE__{} = data, fun) when is_function(fun, 1) do
    new(fn seed, size ->
      data
      |> call(seed, size)
      |> LazyTree.map(fun)
    end)
  end

  # TODO: should this be exposed?
  # QUESTION: In Elixir, we would call this function filter_map,
  # and have it return {:cont, value} | :skip or {:ok, value} | :error.
  # Maybe we should standardize this return type and make this public?
  # I would also likely call the underlying rose tree operation filter_map.

  @doc false
  @spec bind_filter(t(a), (a -> {:pass, t(b)} | :skip), non_neg_integer) :: t(b) when a: term, b: term
  def bind_filter(%__MODULE__{} = data, fun, max_consecutive_failures \\ 10)
      when is_function(fun, 1) and is_integer(max_consecutive_failures) and max_consecutive_failures >= 0 do
    new(fn seed, size ->
      case bind_filter(seed, size, data, fun, max_consecutive_failures) do
        {:ok, lazy_tree} ->
          lazy_tree
        :too_many_failures ->
          raise FilterTooNarrowError, max_consecutive_failures: max_consecutive_failures
      end
    end)
  end

  defp bind_filter(_seed, _size, _data, _mapper, _tries_left = 0) do
    :too_many_failures
  end

  defp bind_filter(seed, size, data, mapper, tries_left) do
    {seed1, seed2} = Random.split(seed)
    lazy_tree = call(data, seed1, size)

    case LazyTree.map_filter(lazy_tree, mapper) do
      {:ok, map_filtered_tree} ->
        tree =
          map_filtered_tree
          |> LazyTree.map(&call(&1, seed2, size))
          |> LazyTree.flatten()
        {:ok, tree}
      :error ->
        bind_filter(seed2, size, data, mapper, tries_left - 1)
    end
  end

  @doc """
  Binds each element generated by `data` to a new generator returned by applying `fun`.

  This function is the basic mechanism for composing generators. It takes a
  generator `data` and invokes `fun` with each element in `data`. `fun` must
  return a new *generator* that is effectively used to generate items from
  now on.

  ## Examples

  Say we wanted to create a generator that returns two-element tuples where the
  first element is a list, and the second element is a random element from that
  list. To do that, we can first generate a list and then bind a function to
  that list; this function will return the list and a random element from it.

      StreamData.bind(StreamData.list_of(StreamData.int()), fn list ->
        StreamData.bind(StreamData.member_of(list), fn elem ->
          StreamData.constant({list, elem})
        end)
      end)

  ## Shrinking

  The generator returned by `bind/2` shrinks by first shrinking the value
  generated by the inner generator and then by shrinking the outer generator
  given as `data`. When `data` shrinks, `fun` is once more applied on the
  shrunk value value and returns a whole new generator, which will most likely
  emit new items.
  """
  @spec bind(t(a), (a -> t(b))) :: t(b) when a: term, b: term
  def bind(%__MODULE__{} = data, fun) when is_function(fun, 1) do
    bind_filter(data, fn generated_term -> {:pass, fun.(generated_term)} end)
  end

  @doc """
  Filters the given generator `data` according to the given `predicate` function.

  Only elements generated by `data` that pass the filter are kept in the
  resulting generator.

  If the filter is too strict, it can happen that too few values generated by
  `data` satisfy it. In case more than `max_consecutive_failures` consecutive
  values don't satisfy the filter, a `StreamData.FilterTooNarrowError` will be
  raised. Try to make sure that your filter takes out only a small subset of the
  elements generated by `data`. When possible, a good way to go around the
  limitations of `filter/3` is to instead transform the generated values in the
  shape you want them instead of filtering out the ones you don't want.

  For example, a generator of odd numbers could be implemented as:

      require Integer
      odd_ints = StreamData.filter(StreamData.int(), &Integer.is_odd/1)
      Enum.take(odd_ints, 3)
      #=> [1, 1, 3]

  However, it will do more work and take more time to generate odd integers
  because it will have to filter out all the even ones that it generates. In
  this case, a better approach would be to generate integers and make sure they
  are odd:

      odd_ints = StreamData.map(StreamData.int(), &(&1 * 2 + 1))
      Enum.take(odd_ints, 3)
      #=> [1, 1, 3]

  ## Shrinking

  All the values that each generated value shrinks to satisfy `predicate` as
  well.
  """
  @spec filter(t(a), (a -> as_boolean(term)), non_neg_integer) :: t(a) when a: term
  def filter(%__MODULE__{} = data, predicate, max_consecutive_failures \\ 10)
      when is_function(predicate, 1) and is_integer(max_consecutive_failures) and max_consecutive_failures >= 0 do
    bind_filter(data, fn term ->
      if predicate.(term) do
        {:pass, constant(term)}
      else
        :skip
      end
    end)
  end

  ### Rich API

  @doc """
  Generates an integer in the given `range`.

  The generation size is ignored since the integer always lies inside `range`.

  ## Shrinking

  Shrinks towards with the smallest absolute value that still lie in `range`.

  ## Examples

      Enum.take(StreamData.int(4..8), 3)
      #=> [6, 7, 7]

  """
  @spec int(Range.t) :: t(integer)
  def int(_lower.._upper = range) do
    new(fn seed, _size ->
      range
      |> Random.uniform_in_range(seed)
      |> int_lazy_tree()
      |> LazyTree.filter(&(&1 in range))
    end)
  end

  defp int_lazy_tree(int) do
    children =
      int
      |> Stream.iterate(&div(&1, 2))
      |> Stream.take_while(&(&1 != 0))
      |> Stream.map(&(int - &1))
      |> Stream.map(&int_lazy_tree/1)

    LazyTree.new(int, children)
  end

  ## Generator modifiers

  # TODO: We have functions about `size` but so far we haven't explained
  # what `size` does and why it matters. Maybe we need to discuss them on
  # the shrinking section in the module doc.

  @doc """
  Resize the given generatod `data` to have fixed size `new_size`.

  The new generator will ignore the generation size and always use `new_size`.

  ## Examples

      data = StreamData.resize(StreamData.int(), 10)
      Enum.take(data, 3)
      #=> [4, -5, -9]

  """
  @spec resize(t(a), size) :: t(a) when a: term
  def resize(%__MODULE__{} = data, new_size) when is_integer(new_size) and new_size >= 0 do
    new(fn seed, _size ->
      call(data, seed, new_size)
    end)
  end

  @doc """
  Returns the generator returned by calling `fun` with the generation size.

  `fun` takes the generation size and has to return a generator, that can use
  that size to its advantage.

  ## Examples

  Let's build a generator that generates integers in double the range `int/0`
  does:

      data = StreamData.sized(fn size ->
        StreamData.resize(StreamData.int(), size * 2)
      end)

      Enum.take(data, 3)
      #=> [0, -1, 5]

  """
  @spec sized((size -> t(a))) :: t(a) when a: term
  def sized(fun) when is_function(fun, 1) do
    new(fn seed, size ->
      new_data = fun.(size)
      call(new_data, seed, size)
    end)
  end

  @doc """
  Scales the size of the given generator `data` according to `size_changer`.

  When generating data from `data`, the generation size will be the result of
  calling `size_changer` with the generation size as its argument. This is
  useful, for example, when a generator should needs to faster or slower than
  the default.

  # TODO: The last sentence above is not readable.

  ## Examples

  Let's create a generator that generates much smaller integers than `int/0`
  when size grows. We can do this by scaling the generation size to the
  logarithm of the generation size.

      data = StreamData.scale(StreamData.int(), fn size ->
        trunc(:math.log(size))
      end)

      Enum.take(data, 3)
      #=> [0, 0, -1]

  Another interesting example is creating a generator that has a maximum. For
  example, say we want to generate binaries but we never want them to be larger
  than 64 bytes:

      small_binaries = StreamData.scale(StreamData.binary(), fn size ->
        min(size, 64)
      end)

  """
  @spec scale(t(a), (size -> size)) :: t(a) when a: term
  def scale(%__MODULE__{} = data, size_changer) when is_function(size_changer, 1) do
    sized(fn size ->
      resize(data, size_changer.(size))
    end)
  end

  # QUESTION: When would I use the function below?

  @doc """
  Makes the values generated by `data` not shrink.

  ## Shrinking

  The generator returned by `no_shrink/1` generates the same values as `data`,
  but such values will not shrink.

  ## Examples

  Let's build a generator of bytes (integers in the `0..255`) range. We can
  build this on top of `int/1`, but for our purposes, it doesn't make sense for
  a byte to shrink towards `0`.

      byte = StreamData.no_shrink(StreamData.int(0..255))
      Enum.take(byte, 3)
      #=> [190, 181, 178]

  """
  @spec no_shrink(t(a)) :: t(a) when a: term
  def no_shrink(%__MODULE__{} = data) do
    new(fn seed, size ->
      %LazyTree{root: root} = call(data, seed, size)
      LazyTree.constant(root)
    end)
  end

  @doc """
  Generates values from different generators with specified probability.

  `frequencies` is a list of `{frequency, data}` where `frequency` is an integer
  and `data` is a generator. The resulting generator will generate data from one
  of the generators in `frequency`, with probability `frequency / vsum_of_frequencies`.

  ## Shrinking

  Each generated value is shrinked, and then this generator shrinks towards
  values generated by generators earlier in the list of `frequencies`.

  ## Examples

  Let's build a generator that returns a binary around 25% of times and a
  integer around 75% of times. We'll use `int/0` first so that generated values
  will shrink towards integers.

      ints_and_some_bins = StreamData.frequency([
        {3, StreamData.int()},
        {1, StreamData.binary()},
      ])
      Enum.take(ints_and_some_bins, 3)
      #=> ["", -2, -1]

  """
  # Right now, it shrinks by first shrinking the generated value, and then
  # shrinking towards earlier generators in "frequencies". Clojure shrinks
  # towards earlier generators *first*, and then shrinks the generated value.
  # An implementation that does this can be:
  #
  #     new(fn seed, size ->
  #       {seed1, seed2} = Random.split(seed)
  #       frequency = Random.uniform_in_range(0..sum - 1, seed1)
  #       index = pick_index(Enum.map(frequencies, &elem(&1, 0)), frequency)
  #       {_frequency, data} = Enum.fetch!(frequencies, index)
  #
  #       tree = call(data, seed2, size)
  #
  #       earlier_children =
  #         frequencies
  #         |> Stream.take(index)
  #         |> Stream.map(&call(elem(&1, 1), seed2, size))
  #       LazyTree.new(tree.root, Stream.concat(earlier_children, tree.children))
  #     end)
  #
  @spec frequency([{pos_integer, t(a)}]) :: t(a) when a: term
  def frequency(frequencies) when is_list(frequencies) do
    sum = Enum.reduce(frequencies, 0, fn {frequency, _data}, acc -> acc + frequency end)
    bind(int(0..sum - 1), &pick_frequency(frequencies, &1))
  end

  defp pick_frequency([{frequency, data} | rest], int) do
    if int < frequency do
      data
    else
      pick_frequency(rest, int - frequency)
    end
  end

  @doc """
  Generates values out of one of the given `datas`.

  `datas` must be a list of generators. The values generated by this generator
  are values generated by generators in `datas`, chosen each time at random.

  ## Shrinking

  The generated value will be shrinked first according to the generator that
  generated it, and then this generator will shrink towards earlier generators
  in `datas`.

  ## Examples

      data = StreamData.one_of([StreamData.int(), StreamData.binary()])
      Enum.take(data, 3)
      #=> [-1, <<28>>, ""]

  """
  @spec one_of([t(a)]) :: t(a) when a: term
  def one_of([_ | _] = datas) do
    bind(int(0..length(datas) - 1), fn index ->
      Enum.fetch!(datas, index)
    end)
  end

  @doc """
  Generates elements taken randomly out of `enum`.

  `enum` must be a non-empty and **finite** enumerable. If given an empty
  enumerable, this function raises an error. If given an infinite enumerable,
  this function will not terminate.

  ## Shrinking

  This generator shrinks towards elements that appear earlier in `enum`.

  ## Examples

      Enum.take(StreamData.member_of([:ok, 4, "hello"]), 3)
      #=> [4, 4, "hello"]

  """
  @spec member_of(Enumerable.t) :: t(term)
  def member_of(enum) do
    enum_length = Enum.count(enum)

    if enum_length == 0 do
      raise "cannot generate elements from an empty enumerable"
    end

    bind(int(0..enum_length - 1), fn index ->
      constant(Enum.fetch!(enum, index))
    end)
  end

  ## Compound data types

  @doc """
  Generates lists where each values is generated by the given `data`.

  Each generated list can contain duplicate elements. The length of the
  generated list is bound by the generation size. If the generation size is `0`,
  the empty list will always be generated.

  ## Shrinking

  This generator shrinks by taking elements out of the generated list and also
  by shrinking the elements of the generated list.

  ## Examples

      Enum.take(StreamData.list_of(StreamData.binary()), 3)
      #=> [[""], [], ["", "w"]

  """
  # We could have an implementation that relies on fixed_list/1 and List.duplicate/2,
  # it would look like this:
  #
  #     new(fn seed, size ->
  #       {seed1, seed2} = Random.split(seed)
  #       length = Random.uniform_in_range(0..size, seed1)
  #       data
  #       |> List.duplicate(length)
  #       |> fixed_list()
  #       |> call(seed2, size)
  #       |> LazyTree.map(&list_lazy_tree/1)
  #       |> LazyTree.flatten()
  #     end)
  #
  @spec list_of(t(a)) :: t([a]) when a: term
  def list_of(%__MODULE__{} = data) do
    new(fn seed, size ->
      {seed1, seed2} = Random.split(seed)
      length = Random.uniform_in_range(0..size, seed1)

      data
      |> call_n_times(seed2, size, length, [])
      |> LazyTree.zip()
      |> LazyTree.map(&list_lazy_tree/1)
      |> LazyTree.flatten()
    end)
  end

  defp call_n_times(_data, _seed, _size, 0, acc) do
    acc
  end

  defp call_n_times(data, seed, size, length, acc) do
    {seed1, seed2} = Random.split(seed)
    call_n_times(data, seed2, size, length - 1, [call(data, seed1, size) | acc])
  end

  defp list_lazy_tree([]) do
    LazyTree.constant([])
  end

  defp list_lazy_tree(list) do
    children =
      (0..length(list) - 1)
      |> Stream.map(&List.delete_at(list, &1))
      |> Stream.map(&list_lazy_tree/1)

    LazyTree.new(list, children)
  end

  @doc """
  Generates a list of elements generated by `data` without duplicates according
  to `uniq_fun`.

  This generator will generate lists where each list is unique according to the
  value returned by applying `uniq_fun` to each element (similarly to how
  `Enum.uniq_by/2` works). If `max_tries` consecutive elements are generated
  that are considered duplicates according to `uniq_fun`, a
  `StreamData.TooManyDuplicatesError` error is raised. For this reason, try to
  make sure to not make `uniq_fun` return values out of a small value space.

  By default `uniq_fun` is the identity function so the behaviour is similar to
  `Enum.uniq/1`.

  ## Shrinking

  This generator shrinks like `list_of/1`, but the shrinked values are unique
  according to `uniq_fun` as well.

  ## Examples

      data = StreamData.uniq_list_of(StreamData.int())
      Enum.take(data, 3)
      #=> [[1], [], [2, 3, 1]]

  """
  @spec uniq_list_of(t(a), (a -> term), non_neg_integer) :: t([a]) when a: term
  def uniq_list_of(data, uniq_fun \\ &(&1), max_tries \\ 10) do
    new(fn seed, size ->
      {seed1, seed2} = Random.split(seed)
      length = Random.uniform_in_range(0..size, seed1)

      data
      |> uniq_list_of(uniq_fun, seed2, size, _seen = MapSet.new(), max_tries, max_tries, length, _acc = [])
      |> LazyTree.zip()
      |> LazyTree.map(&list_lazy_tree(Enum.uniq_by(&1, uniq_fun)))
      |> LazyTree.flatten()
    end)
  end

  defp uniq_list_of(_data, _uniq_fun, _seed, _size, seen, _tries_left = 0, max_tries, remaining, _acc) do
    raise TooManyDuplicatesError, max_tries: max_tries, remaining_to_generate: remaining, generated: seen
  end

  defp uniq_list_of(_data, _uniq_fun, _seed, _size, _seen, _tries_left, _max_tries, _remaining = 0, acc) do
    acc
  end

  defp uniq_list_of(data, uniq_fun, seed, size, seen, tries_left, max_tries, remaining, acc) do
    {seed1, seed2} = Random.split(seed)
    tree = call(data, seed1, size)

    key = uniq_fun.(tree.root)

    if MapSet.member?(seen, key) do
      uniq_list_of(data, uniq_fun, seed2, size, seen, tries_left - 1, max_tries, remaining, acc)
    else
      uniq_list_of(data, uniq_fun, seed2, size, MapSet.put(seen, key), max_tries, max_tries, remaining - 1, [tree | acc])
    end
  end

  @doc ~S"""
  Generates non-empty improper lists where elements of the list are generated
  out of `first` and the improper ending out of `improper`.

  ## Shrinking

  Shrinks towards smaller lists (that are still non-empty, having the improper
  ending) and towards shrinked elements of the list and a shrinked improper
  ending.

  ## Examples

      data = StreamData.nonempty_improper_list_of(StreamData.byte(), StreamData.binary())
      Enum.take(data, 3)
      #=> [["\f"], [56 | <<140, 137>>], [226 | "j"]]

  """
  @spec nonempty_improper_list_of(t(a), t(b)) :: t(nonempty_improper_list(a, b)) when a: term, b: term
  def nonempty_improper_list_of(first, improper) do
    map(tuple({list_of(first), improper}), fn
      {[], ending} ->
        [ending]
      {list, ending} ->
        List.foldr(list, ending, &[&1 | &2])
    end)
  end

  @doc """
  Generates lists of elements out of `first` with a chance of them being
  improper with the improper ending taken out of `improper`.

  Behaves similarly to `nonempty_improper_list_of/2` but can generate empty
  lists and proper lists as well.

  ## Shrinking

  Shrinks towards smaller lists and shrinked elements in those lists, and
  ultimately towards proper lists.

  ## Examples

      data = StreamData.maybe_improper_list_of(StreamData.byte(), StreamData.binary())
      Enum.take(data, 3)
      #=> [[60 | "\""], [], [<<212>>]]

  """
  @spec maybe_improper_list_of(t(a), t(b)) :: t(maybe_improper_list(a, b)) when a: term, b: term
  def maybe_improper_list_of(first, improper) do
    frequency([
      {2, list_of(first)},
      {1, nonempty_improper_list_of(first, improper)},
    ])
  end

  @doc """
  Generates a list of fixed length where each element is generated from the
  corresponding generator in `data`.

  ## Shrinking

  Shrinks by shrinking each element in the generated list according to the
  corresponding generator. Shrinked lists never lose elements.

  ## Examples

      data = StreamData.fixed_list([StreamData.int(), StreamData.binary()])
      Enum.take(data, 3)
      #=> [[1, <<164>>], [2, ".T"], [1, ""]]

  """
  @spec fixed_list([t(a)]) :: t([a]) when a: term
  def fixed_list(datas) when is_list(datas) do
    new(fn seed, size ->
      {trees, _seed} = Enum.map_reduce(datas, seed, fn data, acc ->
        {seed1, seed2} = Random.split(acc)
        {call(data, seed1, size), seed2}
      end)

      LazyTree.zip(trees)
    end)
  end

  @doc """
  Generates tuples where each element is taken out of the corresponding
  generator in the `tuple_datas` tuple.

  ## Shrinking

  Shrinks by shrinking each element in the generated tuple according to the
  corresponding generator.

  ## Examples

      data = StreamData.tuple({StreamData.int(), StreamData.binary()})
      Enum.take(data, 3)
      #=> [{-1, <<170>>}, {1, "<"}, {1, ""}]

  """
  @spec tuple(tuple) :: t(tuple)
  def tuple(tuple_datas) when is_tuple(tuple_datas) do
    tuple_datas
    |> Tuple.to_list()
    |> fixed_list()
    |> map(&List.to_tuple/1)
  end

  @doc """
  Generates maps with keys from `key_data` and values from `value_data`.

  Since maps require keys to be unique, this generator behaves similarly to
  `uniq_list_of/3`: if more than `max_tries` duplicate keys are generated
  consequently, it raises a `StreamData.TooManyDuplicatesError` exception.

  ## Shrinking

  Shrinks towards smallest maps and towards shrinking keys and values according
  to the respective generators.

  ## Examples

      Enum.take(StreamData.map_of(StreamData.int(), StreamData.boolean()), 3)
      #=> [%{}, %{1 => false}, %{-2 => true, -1 => false}]

  """
  @spec map_of(t(key), t(value)) :: t(%{optional(key) => value}) when key: term, value: term
  def map_of(%__MODULE__{} = key_data, %__MODULE__{} = value_data, max_tries \\ 10) do
    tuple({key_data, value_data})
    |> uniq_list_of(fn {key, _value} -> key end, max_tries)
    |> map(&Map.new/1)
  end

  @doc """
  Generates maps with fixed keys and generated values.

  `data_map` is a map of `fixed_key => data` pairs. Maps generated by this
  generator will have the same keys as `data_map` and values corresponding to
  values generated by the generator under those keys.

  ## Shrinking

  This generator shrinks by shrinking the values of the generated map.

  ## Examples

      data = StreamData.fixed_map(%{
        int: StreamData.int(),
        binary: StreamData.binary(),
      })
      Enum.take(data, 3)
      #=> [%{binary: "", int: 1}, %{binary: "", int: -2}, %{binary: "R1^", int: -3}]

  """
  @spec fixed_map(map) :: t(map)
  def fixed_map(data_map) when is_map(data_map) do
    data_map
    |> Enum.map(fn {key, data} -> tuple({constant(key), data}) end)
    |> fixed_list()
    |> map(&Map.new/1)
  end

  @doc """
  Generates keyword lists where values are generated by `value_data`.

  Keys are always atoms.

  ## Shrinking

  This generator shrinks equivalently to a list of key-value tuples generated by
  `list_of/1`, that is, by shrinking the values in each tuple and also reducing
  the size of the generated keyword list.

  ## Examples

      Enum.take(StreamData.keyword_of(StreamData.int()), 3)
      #=> [[], [sY: 1], [t: -1]]

  """
  @spec keyword_of(t(a)) :: t(keyword(a)) when a: term
  def keyword_of(value_data) do
    pairs = tuple({unquoted_atom(), value_data})
    list_of(pairs)
  end

  @doc """
  Constrains the given `enum_data` to be non-empty.

  `enum_data` must be a generator that emits enumerables, such as lists
  and maps. `non_empty/1` will filter out enumerables that are empty
  (`Enum.empty?/1` returns `true`).

  ## Examples

      Enum.take(StreamData.non_empty(StreamData.list_of(StreamData.int())), 3)
      #=> [[1], [-1, 0], [2, 1, -2]]

  """
  @spec non_empty(t(Enumerable.t)) :: t(Enumerable.t)
  def non_empty(enum_data) do
    filter(enum_data, &not(Enum.empty?(&1)))
  end

  # QUESTION: Should we change the arguments order of the function
  # below? So the generator is the first arg and not a function?

  @doc ~S"""
  Generates trees of values generated by `leaf_data`.

  `subtree_fun` is a function that takes a generator and returns a generator
  that "combines" that generator. This generator will pass `leaf_data` to
  `subtree_fun` when it needs to go "one level deeper" in the tree. Note that
  raw values from `leaf_data` can sometimes be generated.

  This is best explained with an example. Say that we want to generate binary
  trees of integers, and that we represent binary trees as either an integer (a
  leaf) a `%Branch{}` struct:

      defmodule Branch do
        defstruct [:left, :right]
      end

  We can start off by creating a generator that generates branches given the
  generator that generates the content of each node (`int/0` in our case):

      defmodule MyTree do
        def branch_data(child_data) do
          children = StreamData.tuple({child_data, child_data})
          StreamData.map(children, fn {left, right} ->
            %Branch{left: left, right: right}
          end)
        end
      end

  Now, we can generate trees by simply using `branch_data` as the `subtree_fun`,
  and `int/0` as `leaf_data`:

      tree_data = StreamData.tree(&MyTree.branch_data/1, StreamData.int())
      Enum.at(StreamData.resize(tree_data, 10), 0)
      #=> %Branch{left: %Branch{left: 4, right: -1}, right: -2}

  ## Shrinking

  Shrinks values and shrinks towards less deep trees.

  ## Examples

  A common example is nested lists:

      data = StreamData.tree(&StreamData.list_of/1, StreamData.int())
      Enum.at(StreamData.resize(data, 10), 0)
      #=> [[], '\t', '\a', [1, 2], -3, [-7, [10]]]

  """
  @spec tree((t(a) -> t(b)), t(a)) :: t(a | b) when a: term, b: term
  def tree(subtree_fun, leaf_data) do
    new(fn seed, size ->
      leaf_data = resize(leaf_data, size)
      {seed1, seed2} = Random.split(seed)
      nodes_on_each_level = random_pseudofactors(trunc(:math.pow(size, 1.1)), seed1)
      data = Enum.reduce(nodes_on_each_level, leaf_data, fn nodes_on_this_level, data_acc ->
        frequency([
          {1, data_acc},
          {2, resize(subtree_fun.(data_acc), nodes_on_this_level)},
        ])
      end)

      call(data, seed2, size)
    end)
  end

  defp random_pseudofactors(n, _seed) when n < 2 do
    [n]
  end

  defp random_pseudofactors(n, seed) do
    {seed1, seed2} = Random.split(seed)
    {factor, _seed} = :rand.uniform_s(trunc(:math.log2(n)), seed1)

    if factor == 1 do
      [n]
    else
      [factor | random_pseudofactors(div(n, factor), seed2)]
    end
  end

  ## Data types

  @doc """
  Generates boolean values.

  ## Shrinking

  Shrinks towards `false`.

  ## Examples

      Enum.take(StreamData.boolean(), 3)
      #=> [true, true, false]

  """
  @spec boolean() :: t(boolean)
  def boolean() do
    member_of([false, true])
  end

  @doc """
  Generates integers bound by the generation size.

  ## Shrinking

  Generated values shrink towards `0`.

  ## Examples

      Enum.take(StreamData.int(), 3)
      #=> [1, -1, -3]

  """
  @spec int() :: t(integer)
  def int() do
    sized(fn size -> int(-size..size) end)
  end

  @doc """
  Generates uniformly distributed floats in the interval `0..1`.

  Note that if you want to have more complex float values, such as negative
  values or bigger values, you can transform this generator. For example, to
  have floats in the interval `0..10`, you can use `map/2`:

      StreamData.map(StreamData.uniform_float(), &(&1 * 10))

  To have sometimes negative floats, you can for example use `bind/2`:

      StreamData.bind(StreamData.boolean(), fn negative? ->
        if negative? do
          StreamData.map(StreamData.uniform_float(), &(-&1))
        else
          StreamData.uniform_float()
        end
      end)

  ## Shrinking

  Values generated by this generator do not shrink.

  ## Examples

      Enum.take(StreamData.uniform_float(), 3)
      #=> [0.5122356680893687, 0.7387020706272481, 0.9613874981766901]

  """
  @spec uniform_float() :: t(float)
  def uniform_float() do
    new(fn seed, _size ->
      {float, _seed} = :rand.uniform_s(seed)
      LazyTree.constant(float)
    end)
  end

  @doc """
  Generates bytes.

  A byte is an integer between `0` and `255`.

  ## Shrinking

  Values generated by this generator do not shrink.

  ## Examples

      Enum.take(StreamData.byte(), 3)
      #=> [102, 161, 13]

  """
  @spec byte() :: t(byte)
  def byte() do
    no_shrink(int(0..255))
  end

  @doc """
  Generates binaries.

  The length of the generated binaries is limited by the generation size.

  ## Shrinking

  Values generated by this generator only shrink by getting smaller, but the
  single bytes do not shrink (given `byte/0` does not shrink).

  ## Examples

      Enum.take(StreamData.binary(), 3)
      #=> [<<1>>, "", "@Q"]

  """
  @spec binary() :: t(binary)
  def binary() do
    map(list_of(byte()), &IO.iodata_to_binary/1)
  end

  @doc """
  Generates a string from the given list of character ranges.

  `char_ranges` has to be a list of enumerables where each enumerable has to be
  an enumerable of characters (`t:char/0`).

  ## Shrinking

  Shrinks towards smaller strings and towards choosing characters that appear
  earlier in `char_ranges`.

  ## Examples

      Enum.take(StreamData.string_from_chars([?a..?c, ?l..?o]), 3)
      #=> ["c", "oa", "lb"]

  """
  @spec string_from_chars([Enumerable.t]) :: t(String.t)
  def string_from_chars(char_ranges) when is_list(char_ranges) do
    char_ranges
    |> Enum.concat()
    |> member_of()
    |> list_of()
    |> map(&List.to_string/1)
  end

  @doc ~S"""
  Generates strings with ascii characters in them.

  Equivalent to `string_from_chars([?\s..?~])`.
  """
  @spec ascii_string() :: t(String.t)
  def ascii_string() do
    string_from_chars([?\s..?~])
  end

  @doc ~S"""
  Generates strings with ascii characters in them.

  Equivalent to `string_from_chars([?a..?z, ?A..?Z, ?0..?9])`.
  """
  @spec alphanumeric_string() :: t(String.t)
  def alphanumeric_string() do
    string_from_chars([?a..?z, ?A..?Z, ?0..?9])
  end

  @doc """
  Generates atoms that don't need to be quoted when written as literals.

  ## Shrinking

  Shrinks towards smaller atoms in the `?a..?z` character set.

  ## Examples

      Enum.take(StreamData.unquoted_atom(), 3)
      #=> [:xF, :y, :B_]

  """
  @spec unquoted_atom() :: t(atom)
  def unquoted_atom() do
    starting_char = frequency([
      {4, member_of(?a..?z)},
      {2, member_of(?A..?Z)},
      {1, constant(?_)},
    ])

    # We limit the size to 255 so that adding the first character doesn't
    # break the system limit of 256 chars in an atom.
    rest = scale(string_from_chars([?a..?z, ?A..?Z, ?0..?9, [?_, ?@]]), &min(&1, 255))

    tuple({starting_char, rest})
    |> resize_atom_data()
    |> map(fn {first, rest} -> String.to_atom(<<first>> <> rest) end)
  end

  defp resize_atom_data(data) do
    scale(data, fn size ->
      min(trunc(:math.pow(size, 0.5)), 256)
    end)
  end

  @doc """
  Generates iolists.

  Iolists are values of the `t:iolist/0` type.

  ## Shrinking

  Shrinks towards smaller and less nested lists and towards bytes instead of
  binaries.

  ## Examples

      Enum.take(StreamData.iolist(), 3)
      #=> [[164 | ""], [225], ["" | ""]]

  """
  @spec iolist() :: t(iolist)
  def iolist() do
    # We try to use binaries that scale slower otherwise we end up with iodata with
    # big binaries at many levels deep.
    scaled_binary = scale(binary(), &trunc(:math.pow(&1, 0.6)))

    improper_ending = one_of([scaled_binary, constant([])])
    tree = tree(&maybe_improper_list_of(&1, improper_ending), one_of([byte(), scaled_binary]))
    map(tree, &List.wrap/1)
  end

  @doc """
  Generates iodata.

  Iodata are values of the `t:iodata/0` type.

  ## Shrinking

  Shrinks towards less nested iodata and ultimately towards smaller binaries.

  ## Examples

      Enum.take(StreamData.iodata(), 3)
      #=> [[""], <<198>>, [115, 172]]

  """
  @spec iodata() :: t(iodata)
  def iodata() do
    frequency([
      {3, binary()},
      {2, iolist()},
    ])
  end

  ## Enumerable

  defimpl Enumerable do
    @initial_size 1
    @max_size 100

    def reduce(data, acc, fun) do
      reduce(data, acc, fun, :rand.seed_s(:exs64), @initial_size)
    end

    defp reduce(_data, {:halt, acc}, _fun, _seed, _size) do
      {:halted, acc}
    end

    defp reduce(data, {:suspend, acc}, fun, seed, size) do
      {:suspended, acc, &reduce(data, &1, fun, seed, size)}
    end

    defp reduce(data, {:cont, acc}, fun, seed, size) do
      {seed1, seed2} = Random.split(seed)
      %LazyTree{root: next} = @for.call(data, seed1, size)
      size = if(size < @max_size, do: size + 1, else: size)
      reduce(data, fun.(next, acc), fun, seed2, size)
    end

    def count(_data), do: {:error, __MODULE__}

    def member?(_data, _term), do: {:error, __MODULE__}
  end
end
