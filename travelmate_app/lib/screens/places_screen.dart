import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:travelmate_app/config/env.dart';
import 'package:travelmate_app/providers/location_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:travelmate_app/services/mongodb_service.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  List<dynamic> _places = [];
  bool _isLoading = true;
  String _error = '';
  String _selectedCategory = 'all';
  double _radius =
      2000; // Default radius in meters (2km for better real results)
  Position? _userPosition;
  bool _showMapView = false; // Toggle between list and map view
  final MapController _mapController = MapController();

  final List<Map<String, dynamic>> _categories = [
    {'key': 'all', 'label': 'All Places', 'icon': Icons.place},
    {
      'key': 'tourism',
      'label': 'Tourist Attractions',
      'icon': Icons.camera_alt,
    },
    {
      'key': 'restaurant',
      'label': 'Restaurants & Food',
      'icon': Icons.restaurant,
    },
    {'key': 'accommodation', 'label': 'Hotels & Lodging', 'icon': Icons.hotel},
    {'key': 'shopping', 'label': 'Shopping', 'icon': Icons.shopping_bag},
    {'key': 'entertainment', 'label': 'Entertainment', 'icon': Icons.movie},
    {'key': 'healthcare', 'label': 'Healthcare', 'icon': Icons.local_hospital},
    {'key': 'transport', 'label': 'Transport', 'icon': Icons.directions_bus},
  ];

  @override
  void initState() {
    super.initState();
    _getUserLocation();
  }

  Future<void> _getUserLocation() async {
    final location = Provider.of<LocationProvider>(
      context,
      listen: false,
    ).currentPosition;
    if (location != null) {
      setState(() {
        _userPosition = location;
      });
      _fetchNearbyPlaces(location.latitude, location.longitude);
    }
  }

  // Store places data to MongoDB
  void _storePlacesData(List<dynamic> places, double lat, double lon) async {
    try {
      final mongoService = MongoDBService();
      final locKey = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';

      await mongoService.insertPlacesLog({
        'location': {'locKey': locKey, 'latitude': lat, 'longitude': lon},
        'places': places,
        'category': _selectedCategory,
        'radius': _radius,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('MongoDB places storage failed: $e');
    }
  }

  Future<void> _fetchNearbyPlaces(double lat, double lon) async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      String url =
          '${Env.baseUrl}/places?lat=$lat&lon=$lon&radius=${_radius.toInt()}';
      if (_selectedCategory != 'all') {
        url += '&category=$_selectedCategory';
      }

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        // Handle the new API response format with metadata
        List<dynamic> places;
        if (responseData is Map && responseData.containsKey('places')) {
          places = responseData['places'] as List<dynamic>;
        } else if (responseData is List) {
          // Fallback for old format
          places = responseData;
        } else {
          places = [];
        }

        setState(() {
          _places = places;
          _error = '';
        });

        // Store places data to MongoDB
        _storePlacesData(places, lat, lon);
      } else {
        final errorData = json.decode(response.body);
        String errorMessage = 'Failed to load places: ${response.statusCode}';

        if (errorData is Map) {
          if (errorData.containsKey('message')) {
            errorMessage = errorData['message'];
          }
          if (errorData.containsKey('suggestions') &&
              errorData['suggestions'] is List) {
            final suggestions = (errorData['suggestions'] as List).join(', ');
            errorMessage += '\nSuggestions: $suggestions';
          }
        }

        print(
          'API Error: ${response.statusCode} - ${response.body}',
        ); // Debug log
        setState(() {
          _error = errorMessage;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Connection error: ${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Open map for a specific place
  Future<void> _openPlaceOnMap(double lat, double lon, String placeName) async {
    final url = Uri.parse(
      'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=18/$lat/$lon',
    );

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // Fallback to Google Maps
        final googleUrl = Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
        );
        if (await canLaunchUrl(googleUrl)) {
          await launchUrl(googleUrl, mode: LaunchMode.externalApplication);
        } else {
          throw Exception('Could not launch maps');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open map for $placeName'),
            action: SnackBarAction(
              label: 'RETRY',
              onPressed: () => _openPlaceOnMap(lat, lon, placeName),
            ),
          ),
        );
      }
    }
  }

  // Calculate distance from user location
  double _calculateDistance(double placeLat, double placeLon) {
    if (_userPosition == null) return 0.0;

    return Geolocator.distanceBetween(
      _userPosition!.latitude,
      _userPosition!.longitude,
      placeLat,
      placeLon,
    );
  }

  // Check if place is within geofence
  bool _isWithinGeofence(double placeLat, double placeLon) {
    if (_userPosition == null) return false;

    final distance = _calculateDistance(placeLat, placeLon);
    return distance <= _radius;
  }

  // Show filter dialog for radius adjustment
  void _showFilterDialog() {
    double tempRadius = _radius; // Temporary radius for preview
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.tune, color: Colors.blue[600]),
              const SizedBox(width: 8),
              const Text('Search Filters - Real Places Only'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Radius display with animated color change
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Text(
                  'Search Radius: ${(tempRadius / 1000).toStringAsFixed(1)} km',
                  style: TextStyle(
                    fontSize: 16, 
                    fontWeight: FontWeight.w600,
                    color: Colors.blue[800],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Find real attractions, restaurants, and places within your selected area',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              // Enhanced slider with better styling
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.blue[600],
                  inactiveTrackColor: Colors.blue[200],
                  thumbColor: Colors.blue[700],
                  overlayColor: Colors.blue[100],
                  valueIndicatorColor: Colors.blue[700],
                  valueIndicatorTextStyle: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                child: Slider(
                  value: tempRadius,
                  min: 500, // 0.5km minimum
                  max: 50000, // 50km maximum
                  divisions: 99, // 0.5km increments
                  label: '${(tempRadius / 1000).toStringAsFixed(1)} km',
                  onChanged: (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              // Min/Max labels
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '0.5km',
                      style: TextStyle(
                        color: Colors.grey[600], 
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '50km',
                      style: TextStyle(
                        color: Colors.grey[600], 
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Quick selection label
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Quick Select:',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Enhanced quick selection buttons
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildQuickRadiusButton('1km', 1000, tempRadius, (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  }),
                  _buildQuickRadiusButton('5km', 5000, tempRadius, (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  }),
                  _buildQuickRadiusButton('10km', 10000, tempRadius, (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  }),
                  _buildQuickRadiusButton('25km', 25000, tempRadius, (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  }),
                  _buildQuickRadiusButton('50km', 50000, tempRadius, (value) {
                    setDialogState(() {
                      tempRadius = value;
                    });
                  }),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey[600],
              ),
              child: const Text('Close'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                // Apply the selected radius
                setState(() {
                  _radius = tempRadius;
                });
                // Fetch new places with updated radius
                if (_userPosition != null) {
                  _fetchNearbyPlaces(
                    _userPosition!.latitude,
                    _userPosition!.longitude,
                  );
                }
                Navigator.pop(context);
                
                // Show feedback snackbar
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Search radius updated to ${(tempRadius / 1000).toStringAsFixed(1)}km',
                    ),
                    duration: const Duration(seconds: 2),
                    backgroundColor: Colors.green[600],
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[600],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }

  // Helper method for quick radius selection buttons
  Widget _buildQuickRadiusButton(
    String label, 
    double radiusValue, 
    double currentRadius, 
    Function(double) onRadiusChanged
  ) {
    final isSelected = currentRadius == radiusValue;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            onRadiusChanged(radiusValue);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? Colors.blue[600] : Colors.grey[100],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected ? Colors.blue[600]! : Colors.grey[300]!,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: isSelected ? [
                BoxShadow(
                  color: Colors.blue[200]!,
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ] : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[700],
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Build the map view
  Widget _buildMapView() {
    if (_userPosition == null) {
      return const Center(child: Text('Location not available'));
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(
              _userPosition!.latitude,
              _userPosition!.longitude,
            ),
            initialZoom: 13.0,
            minZoom: 5.0,
            maxZoom: 18.0,
          ),
          children: [
            // Map tiles
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.travelmate_app',
              maxZoom: 18,
            ),

            // Circle layer to show search radius
            CircleLayer(
              circles: [
                CircleMarker(
                  point: LatLng(
                    _userPosition!.latitude,
                    _userPosition!.longitude,
                  ),
                  radius: _radius,
                  useRadiusInMeter: true,
                  color: Colors.blue.withOpacity(0.1),
                  borderColor: Colors.blue,
                  borderStrokeWidth: 2,
                ),
              ],
            ),

            // Markers for places and user location
            MarkerLayer(
              markers: [
                // User location marker
                Marker(
                  point: LatLng(
                    _userPosition!.latitude,
                    _userPosition!.longitude,
                  ),
                  width: 60,
                  height: 60,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.blue,
                    ),
                    child: const Icon(
                      Icons.person_pin_circle,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
                // Place markers
                ..._places.map((place) {
                  final lat = place['lat']?.toDouble() ?? 0.0;
                  final lon = place['lon']?.toDouble() ?? 0.0;
                  return Marker(
                    point: LatLng(lat, lon),
                    width: 40,
                    height: 40,
                    child: GestureDetector(
                      onTap: () => _showPlaceBottomSheet(place),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _getMarkerColor(place['type'] ?? 'attraction'),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Icon(
                          _getPlaceIcon(place['type'] ?? 'attraction'),
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Build the list view
  Widget _buildListView() {
    return ListView.builder(
      itemCount: _places.length,
      itemBuilder: (context, index) {
        final place = _places[index];
        final distance = _calculateDistance(
          place['lat']?.toDouble() ?? 0.0,
          place['lon']?.toDouble() ?? 0.0,
        );

        return EnhancedPlaceCard(
          name: place['name'] ?? 'Unknown Place',
          address: place['address'] ?? 'Address not available',
          distance: distance / 1000, // Convert to km
          placeType: place['type'] ?? 'attraction',
          rating: place['rating']?.toDouble(),
          openingHours: place['opening_hours'],
          latitude: place['lat']?.toDouble() ?? 0.0,
          longitude: place['lon']?.toDouble() ?? 0.0,
          onMapTap: () => _openPlaceOnMap(
            place['lat']?.toDouble() ?? 0.0,
            place['lon']?.toDouble() ?? 0.0,
            place['name'] ?? 'Unknown Place',
          ),
          onViewOnMap: () {
            setState(() {
              _showMapView = true;
            });
            _mapController.move(
              LatLng(
                place['lat']?.toDouble() ?? 0.0,
                place['lon']?.toDouble() ?? 0.0,
              ),
              16.0,
            );
          },
          isWithinGeofence: _isWithinGeofence(
            place['lat']?.toDouble() ?? 0.0,
            place['lon']?.toDouble() ?? 0.0,
          ),
        );
      },
    );
  }

  // Get marker color based on place type
  Color _getMarkerColor(String placeType) {
    switch (placeType.toLowerCase()) {
      case 'restaurant':
      case 'food':
        return Colors.orange;
      case 'hotel':
      case 'accommodation':
        return Colors.blue;
      case 'tourism':
      case 'attraction':
        return Colors.green;
      case 'shopping':
        return Colors.purple;
      case 'entertainment':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  // Get place icon based on type
  IconData _getPlaceIcon(String placeType) {
    switch (placeType.toLowerCase()) {
      case 'restaurant':
      case 'food':
        return Icons.restaurant;
      case 'hotel':
      case 'accommodation':
        return Icons.hotel;
      case 'tourism':
      case 'attraction':
        return Icons.camera_alt;
      case 'shopping':
        return Icons.shopping_bag;
      case 'entertainment':
        return Icons.movie;
      default:
        return Icons.place;
    }
  }

  // Show place details in bottom sheet when marker is tapped
  void _showPlaceBottomSheet(Map<String, dynamic> place) {
    final distance = _calculateDistance(
      place['lat']?.toDouble() ?? 0.0,
      place['lon']?.toDouble() ?? 0.0,
    );

    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getPlaceIcon(place['type'] ?? 'attraction'),
                  color: _getMarkerColor(place['type'] ?? 'attraction'),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    place['name'] ?? 'Unknown Place',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              place['address'] ?? 'Address not available',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              '${(distance / 1000).toStringAsFixed(1)} km away',
              style: TextStyle(
                color: Colors.blue[700],
                fontWeight: FontWeight.w500,
              ),
            ),
            if (place['opening_hours'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Hours: ${place['opening_hours']}',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _openPlaceOnMap(
                        place['lat']?.toDouble() ?? 0.0,
                        place['lon']?.toDouble() ?? 0.0,
                        place['name'] ?? 'Unknown Place',
                      );
                    },
                    icon: const Icon(Icons.directions),
                    label: const Text('Get Directions'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final location = Provider.of<LocationProvider>(context).currentPosition;
    final locationError = Provider.of<LocationProvider>(context).error;

    if (locationError.isNotEmpty) {
      return Center(child: Text(locationError));
    }

    if (location != null && _isLoading && _userPosition == null) {
      setState(() {
        _userPosition = location;
      });
      _fetchNearbyPlaces(location.latitude, location.longitude);
    }

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with title and controls
            Row(
              children: [
                Text(
                  'Nearby Places',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[800],
                  ),
                ),
                const Spacer(),
                // View toggle buttons
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.list,
                          color: !_showMapView
                              ? Colors.blue[700]
                              : Colors.grey[600],
                        ),
                        onPressed: () {
                          setState(() {
                            _showMapView = false;
                          });
                        },
                        tooltip: 'List View',
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.map,
                          color: _showMapView
                              ? Colors.blue[700]
                              : Colors.grey[600],
                        ),
                        onPressed: () {
                          setState(() {
                            _showMapView = true;
                          });
                        },
                        tooltip: 'Map View',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => _showFilterDialog(),
                  tooltip: 'Search Settings',
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: location != null
                      ? () => _fetchNearbyPlaces(
                          location.latitude,
                          location.longitude,
                        )
                      : null,
                  tooltip: 'Refresh Places',
                ),
              ],
            ),

            // Category filter chips
            const SizedBox(height: 8),
            SizedBox(
              height: 50,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _categories.length,
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  final isSelected = _selectedCategory == category['key'];

                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: FilterChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            category['icon'],
                            size: 16,
                            color: isSelected ? Colors.white : Colors.blue[800],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            category['label'],
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.blue[800],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          _selectedCategory = category['key'];
                        });
                        if (location != null) {
                          _fetchNearbyPlaces(
                            location.latitude,
                            location.longitude,
                          );
                        }
                      },
                      selectedColor: Colors.blue[600],
                      backgroundColor: Colors.blue[50],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // Radius and count info
            if (_places.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.location_on, size: 16, color: Colors.green[700]),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${_places.length} places within ${(_radius / 1000).toStringAsFixed(1)}km',
                        style: TextStyle(
                          color: Colors.green[700],
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    // Debug button to force refresh
                    TextButton(
                      onPressed: location != null
                          ? () {
                              print('Force refreshing places...');
                              _fetchNearbyPlaces(
                                location.latitude,
                                location.longitude,
                              );
                            }
                          : null,
                      child: Text(
                        'Refresh',
                        style: TextStyle(
                          color: Colors.green[700],
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Content area - Map or List view
            if (_isLoading)
              const Expanded(child: Center(child: CircularProgressIndicator())),

            if (_error.isNotEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 64,
                        color: Colors.red[300],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _error,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: location != null
                            ? () => _fetchNearbyPlaces(
                                location.latitude,
                                location.longitude,
                              )
                            : null,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),

            if (!_isLoading && _places.isEmpty && _error.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No places found nearby',
                        style: TextStyle(color: Colors.grey[600], fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Try increasing the search radius or changing the category',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Current settings: ${(_radius / 1000).toStringAsFixed(1)}km radius, $_selectedCategory category',
                        style: TextStyle(color: Colors.grey[400], fontSize: 10),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),

            // Map or List view
            if (!_isLoading && _places.isNotEmpty)
              Expanded(
                child: _showMapView ? _buildMapView() : _buildListView(),
              ),
          ],
        ),
      ),
      floatingActionButton: _places.isNotEmpty
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _showMapView = !_showMapView;
                });
              },
              child: Icon(_showMapView ? Icons.list : Icons.map),
              tooltip: _showMapView
                  ? 'Switch to List View'
                  : 'Switch to Map View',
            )
          : null,
    );
  }
}

// Enhanced Place Card Widget with additional features
class EnhancedPlaceCard extends StatelessWidget {
  final String name;
  final String address;
  final double distance;
  final String placeType;
  final double? rating;
  final String? openingHours;
  final double latitude;
  final double longitude;
  final VoidCallback onMapTap;
  final VoidCallback? onViewOnMap;
  final bool isWithinGeofence;

  const EnhancedPlaceCard({
    super.key,
    required this.name,
    required this.address,
    required this.distance,
    required this.placeType,
    this.rating,
    this.openingHours,
    required this.latitude,
    required this.longitude,
    required this.onMapTap,
    this.onViewOnMap,
    required this.isWithinGeofence,
  });

  IconData _getPlaceIcon() {
    switch (placeType.toLowerCase()) {
      case 'restaurant':
      case 'food':
        return Icons.restaurant;
      case 'hotel':
      case 'accommodation':
        return Icons.hotel;
      case 'tourism':
      case 'attraction':
        return Icons.camera_alt;
      case 'shopping':
        return Icons.shopping_bag;
      case 'entertainment':
        return Icons.movie;
      default:
        return Icons.place;
    }
  }

  Color _getTypeColor() {
    switch (placeType.toLowerCase()) {
      case 'restaurant':
      case 'food':
        return Colors.orange;
      case 'hotel':
      case 'accommodation':
        return Colors.blue;
      case 'tourism':
      case 'attraction':
        return Colors.green;
      case 'shopping':
        return Colors.purple;
      case 'entertainment':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isWithinGeofence
              ? Border.all(color: Colors.green, width: 2)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row with icon, name, and actions
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _getTypeColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _getPlaceIcon(),
                      color: _getTypeColor(),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (rating != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              ...List.generate(5, (index) {
                                return Icon(
                                  index < (rating! / 2).round()
                                      ? Icons.star
                                      : Icons.star_border,
                                  color: Colors.amber,
                                  size: 16,
                                );
                              }),
                              const SizedBox(width: 4),
                              Text(
                                rating!.toStringAsFixed(1),
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Geofence indicator
                  if (isWithinGeofence)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'NEARBY',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 12),

              // Address
              Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      address,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              // Opening hours if available
              if (openingHours != null && openingHours!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.access_time, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        openingHours!,
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 12),

              // Footer with distance and actions
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${distance.toStringAsFixed(1)} km',
                      style: TextStyle(
                        color: Colors.blue[700],
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _getTypeColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      placeType.toUpperCase(),
                      style: TextStyle(
                        color: _getTypeColor(),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (onViewOnMap != null)
                    IconButton(
                      icon: const Icon(Icons.map),
                      onPressed: onViewOnMap,
                      iconSize: 20,
                      color: Colors.green[700],
                      tooltip: 'View on Map',
                    ),
                  IconButton(
                    icon: const Icon(Icons.directions),
                    onPressed: onMapTap,
                    iconSize: 20,
                    color: Colors.blue[700],
                    tooltip: 'Get Directions',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
