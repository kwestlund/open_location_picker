import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_location_picker/open_location_picker.dart';

/// search app bar
class MapAppBar extends StatefulWidget with PreferredSizeWidget {
  final OpenMapBloc bloc;
  final MapController controller;
  final ValueChanged<SelectedLocation>? onDone;
  final String searchHint;
  final SearchFilters? searchFilters;
  final Function(LatLng latLng, double zoom) moveTo;
  final IconData? zoomInIcon;
  final IconData? zoomOutIcon;
  final Widget? searchLoadingIndicator;
  final IconData? searchDoneIcon;
  final IconData? mapBackIcon;

  const MapAppBar({
    Key? key,
    required this.bloc,
    required this.controller,
    required this.moveTo,
    required this.onDone,
    required this.searchHint,
    required this.searchFilters,
    this.zoomInIcon,
    this.zoomOutIcon,
    this.searchLoadingIndicator,
    this.searchDoneIcon,
    this.mapBackIcon,
  }) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  State<MapAppBar> createState() => _MapAppBarState();
}

class _MapAppBarState extends State<MapAppBar> {
  late FocusNode _focusNode;
  Timer? timer;
  void search(String? q, OpenMapState state) async {
    timer?.cancel();
    if (q == null || q.isEmpty) {
      widget.bloc.emit(OpenMapState.selected(state.selected));
      return;
    }
    var query = q;

    timer = Timer(const Duration(milliseconds: 700), () async {
      var oldResults = state.maybeWhen(
        orElse: () => <FormattedLocation>[],
        searching: (_, __, values) => values,
        results: (_, __, values) => values,
      );

      try {
        widget.bloc.emit(OpenMapState.searching(
          selected: state.selected,
          query: query,
          oldResults: oldResults,
        ));
        Locale locale = Localizations.localeOf(context);

        /// KPW
        var results = await boundedSearch(locale, query);
        widget.bloc.emit(OpenMapState.results(
          selected: state.selected,
          query: query,
          searchResults: results,
        ));
      } catch (e) {
        if (mounted) {
          OpenMapSettings.of(context)?.onError?.call(context, e);
        }
        widget.bloc.emit(state);
      }
    });
  }

  @override
  void initState() {
    _focusNode = FocusNode();
    super.initState();
  }

  @override
  void dispose() {
    timer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void zoomIn() {
    widget.moveTo(widget.controller.center, widget.controller.zoom + 1);
  }

  void zoomOut() {
    widget.moveTo(widget.controller.center, widget.controller.zoom - 1);
  }

  Widget _doneButton(SelectedLocation location) {
    return location.when(
      multi: (List<FormattedLocation> selected) {
        return IconButton(
          icon: Icon(widget.searchDoneIcon ?? Icons.done),
          onPressed: selected.isNotEmpty
              ? () {
                  widget.onDone?.call(location);
                }
              : null,
        );
      },
      single: (FormattedLocation? selected) {
        return IconButton(
          icon: Icon(widget.searchDoneIcon ?? Icons.done),
          onPressed: selected != null
              ? () {
                  widget.onDone?.call(location);
                }
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: widget.bloc.stream,
      initialData: widget.bloc.state,
      builder: (BuildContext context, AsyncSnapshot<OpenMapState> snapshot) {
        var state = snapshot.data!;

        return AppBar(
          leading: state.mapOrNull(
            selected: (_) => IconButton(
              icon: Icon(widget.mapBackIcon ?? Icons.adaptive.arrow_back),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
            searching: (_) => Center(
                child: widget.searchLoadingIndicator ??
                    const CircularProgressIndicator.adaptive()),
          ),
          backgroundColor: Theme.of(context).colorScheme.surface,
          titleTextStyle: Theme.of(context).textTheme.bodyText1,
          iconTheme: Theme.of(context).iconTheme,
          elevation: state.maybeMap(
            orElse: () => 4,
            searching: (_) => 0,
            results: (_) => 0,
          ),
          actions: [
            StreamBuilder(
                stream: widget.controller.mapEventStream,
                builder: (context, snapshot) {
                  return IconButton(
                    onPressed: (widget.controller.zoom < 18) ? zoomIn : null,
                    icon: Icon(widget.zoomInIcon ?? Icons.zoom_in_rounded),
                  );
                }),
            StreamBuilder(
                stream: widget.controller.mapEventStream,
                builder: (context, snapshot) {
                  return IconButton(
                    onPressed: (widget.controller.zoom > 1) ? zoomOut : null,
                    icon: Icon(widget.zoomOutIcon ?? Icons.zoom_out_rounded),
                  );
                }),
            state.when(
              selected: _doneButton,
              reversing: (value, _) => _doneButton(value),
              searching: (value, _, __) => _doneButton(value),
              results: (value, _, __) => _doneButton(value),
            ),
          ],
          title: TextFormField(
            focusNode: _focusNode,
            onChanged: (v) => search(v, state),
            initialValue: state.whenOrNull(
              searching: (_, q, __) => q,
              results: (_, q, __) => q,
            ),
            decoration: InputDecoration(
              hintText: widget.searchHint,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              fillColor: Colors.transparent,
            ),
          ),
        );
      },
    );
  }

  /// KPW
  Future<List<FormattedLocation>> boundedSearch(
      Locale locale, String query) async {
    // start expanding search with location center in map bounds
    if (widget.controller.bounds == null) return [];
    return await expandingSearch(locale, query, widget.controller.bounds!.center,
        widget.controller.bounds, ReverseZoom.majorStreets);
  }

  expandingSearch(Locale locale, String query, LatLng location,
      LatLngBounds? bounds, ReverseZoom? zoom) async {
    List<FormattedLocation> results = await Reverse.search(
      locale: locale,
      searchFilters: applyBounds(widget.searchFilters, bounds),
      query: query,
    );
    if (results.isNotEmpty) return results;
    if (zoom == null) return null;
    zoom = expandZoom(zoom);
    return expandingSearch(locale, query, location,
        await expandBounds(locale, location, zoom), zoom);
  }

  SearchFilters? applyBounds(
      SearchFilters? searchFilters, LatLngBounds? bounds) {
    if (bounds == null ||
        bounds.southWest == null ||
        bounds.northEast == null) {
      return searchFilters;
    }
    return SearchFilters(
        countryCodes: searchFilters?.countryCodes,
        excludePlaceIds: searchFilters?.excludePlaceIds,
        limit: searchFilters?.limit,
        // use view bounds as default search bounds
        viewBox: searchFilters?.viewBox ??
            ViewBox(bounds.southWest!, bounds.northEast!, true),
        email: searchFilters?.email,
        dedupe: searchFilters?.dedupe);
  }

  Future<LatLngBounds?> expandBounds(
      locale, LatLng location, ReverseZoom? zoom) async {
    if (zoom == null) return null;
    FormattedLocation formattedLocation = await Reverse.reverseLocation(
        locale: locale, location: location, zoom: zoom);
    return formattedLocation.boundingBox;
  }

  ReverseZoom? expandZoom(ReverseZoom zoom) {
    switch (zoom) {
      case ReverseZoom.suburb:
        return ReverseZoom.city;
      case ReverseZoom.majorStreets:
        return ReverseZoom.suburb;
      case ReverseZoom.majorAndMinorStreets:
        return ReverseZoom.majorStreets;
      case ReverseZoom.building:
        return ReverseZoom.majorAndMinorStreets;
      default:
        return null;
    }
  }
}
