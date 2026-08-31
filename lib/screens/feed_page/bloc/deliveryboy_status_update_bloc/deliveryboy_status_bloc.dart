import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../config/api_base_helper.dart';
import '../../../../config/api_routes.dart';
import '../../../../config/global.dart';
import '../../../../utils/location_tracker.dart';
import '../../repo/deliveryboy_status.dart';
import 'deliveryboy_status_event.dart';
import 'deliveryboy_status_state.dart';

class DeliveryBoyStatusBloc
    extends Bloc<DeliveryBoyStatusEvent, DeliveryBoyStatusState> {
  final LocationTracker _locationTracker = LocationTracker();
  final DeliveryBoyStatusRepo _deliveryBoyStatusRepo = DeliveryBoyStatusRepo();
  bool _isProcessing = false;
  bool _isCheckingApi = false;

  DeliveryBoyStatusBloc() : super(DeliveryBoyStatusInitial()) {
    on<SyncInitialStatus>(_onSyncInitialStatus);
    on<CheckApiStatus>(_onCheckApiStatus);
    on<ToggleStatus>(_onToggleStatus);
  }

  @override
  Future<void> close() {
    _locationTracker.stopTracking();
    return super.close();
  }

  Future<void> _onSyncInitialStatus(
    SyncInitialStatus event,
    Emitter<DeliveryBoyStatusState> emit,
  ) async {
    try {
      // Emit the local status immediately
      emit(DeliveryBoyStatusLoaded(isOnline: event.isOnline));

      // Start location services if online
      if (event.isOnline) {
        _locationTracker.startTracking();
      }
    } catch (e) {
      emit(
        DeliveryBoyStatusError(
          'Failed to sync initial status: ${e.toString()}',
          isOnline: state.isOnline,
        ),
      );
    }
  }

  Future<void> _onCheckApiStatus(
    CheckApiStatus event,
    Emitter<DeliveryBoyStatusState> emit,
  ) async {
    if (_isCheckingApi) {
      return;
    }

    _isCheckingApi = true;

    try {
      await Global.refreshCachedToken();

      Map<String, dynamic> response;

      // First try the profile endpoint
      try {
        response = await ApiBaseHelper.getApi(
          url: deliveryBoyProfileApi,
          useAuthToken: true,
          params: {},
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw TimeoutException(
              'Profile endpoint timed out after 10 seconds',
            );
          },
        );
      } catch (e) {
        // Fallback to status endpoint if profile fails
        response = await ApiBaseHelper.getApi(
          url: deliveryBoyStatusApi,
          useAuthToken: true,
          params: {},
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw TimeoutException(
              'Status endpoint also timed out after 5 seconds',
            );
          },
        );
      }

      if (response['success'] == true) {
        bool isOnline = false;
        bool isVerified = true;

        if (response['data'] != null) {
          // Try to get status from different possible locations
          isOnline =
              response['data']?['is_online'] ??
              response['data']?['delivery_boy']?['status'] == 'active' ??
              response['data']?['delivery_boy']?['is_online'] ??
              false;
        }

        emit(
          DeliveryBoyStatusLoaded(isOnline: isOnline, isVerified: isVerified),
        );

        // Update local storage
        await Global.setDeliveryBoyStatus(isOnline);

        // Start/stop location services based on API status
        if (isOnline) {
          _locationTracker.startTracking();
        } else {
          _locationTracker.stopTracking();
        }
      } else {
        // Explicitly check for verification error
        final String? message = response['message'];
        final bool isUnverified =
            message != null &&
            message.toLowerCase().contains('not been verified yet');

        if (isUnverified) {
          emit(
            DeliveryBoyStatusLoaded(
              isOnline: false,
              isVerified: false,
              message: message,
            ),
          );
          // Also force local status to offline for unverified accounts
          await Global.setDeliveryBoyStatus(false);
          return;
        }

        emit(
          DeliveryBoyStatusError(
            response['message'] ?? 'Failed to check status',
            isOnline: state.isOnline,
            isVerified: state.isVerified,
          ),
        );
      }
    } catch (e) {
      emit(
        DeliveryBoyStatusError(
          'Failed to check API status: ${e.toString()}',
          isOnline: state.isOnline,
          isVerified: state.isVerified,
        ),
      );
    } finally {
      _isCheckingApi = false;
    }
  }

  Future<void> _onToggleStatus(
    ToggleStatus event,
    Emitter<DeliveryBoyStatusState> emit,
  ) async {
    if (_isProcessing) {
      return;
    }

    _isProcessing = true;

    // Emit loading state immediately for better UX
    final currentIsOnline = state.isOnline;
    final currentIsVerified = state.isVerified;

    // Prevent toggling to online if not verified
    if (event.isOnline && !currentIsVerified) {
      emit(
        DeliveryBoyStatusError(
          'Your account has not been verified yet.',
          isOnline: false,
          isVerified: false,
        ),
      );
      _isProcessing = false;
      return;
    }

    emit(
      DeliveryBoyStatusLoading(
        isOnline: currentIsOnline,
        isVerified: currentIsVerified,
      ),
    );

    try {
      if (event.isOnline) {
        // Going online - simplified process

        double? latitude;
        double? longitude;

        // Try to get location with multiple fallbacks
        try {
          // 1. Check LocationTracker first (if it's already running somehow)
          if (_locationTracker.currentLocation != null) {
            latitude = _locationTracker.currentLocation!.latitude;
            longitude = _locationTracker.currentLocation!.longitude;
          }

          // 2. Request fresh location from Geolocator
          if (latitude == null || longitude == null) {
            // Check if service is enabled
            bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
            if (!serviceEnabled) {
              // Service is not enabled, we can't get fresh location here
            } else {
              // Check location permissions
              LocationPermission permissionStatus =
                  await Geolocator.checkPermission();
              if (permissionStatus == LocationPermission.denied) {
                permissionStatus = await Geolocator.requestPermission();
              }

              if (permissionStatus == LocationPermission.whileInUse ||
                  permissionStatus == LocationPermission.always) {
                // Request a FRESH position, not a last known one
                Position position = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.high,
                    timeLimit: Duration(seconds: 8),
                  ),
                );
                latitude = position.latitude;
                longitude = position.longitude;
              }
            }
          }
        } catch (e) {
          // Ignored - move to next fallback
        }

        // 3. Fallback: Try to get coordinates from profile/delivery zone center
        if (latitude == null || longitude == null) {
          try {
            await Global.refreshCachedToken();
            final profileResponse = await ApiBaseHelper.getApi(
              url: deliveryBoyProfileApi,
              useAuthToken: true,
              params: {},
            ).timeout(const Duration(seconds: 5));

            if (profileResponse['success'] == true &&
                profileResponse['data'] != null) {
              final data = profileResponse['data'];
              final deliveryBoy = data['delivery_boy'];

              if (deliveryBoy != null) {
                // Try direct boy coords first
                latitude = double.tryParse(
                  deliveryBoy['latitude']?.toString() ?? '',
                );
                longitude = double.tryParse(
                  deliveryBoy['longitude']?.toString() ?? '',
                );

                // Fallback to zone center if boy doesn't have fixed coords
                if (latitude == null && deliveryBoy['delivery_zone'] != null) {
                  final zone = deliveryBoy['delivery_zone'];
                  latitude = double.tryParse(
                    zone['center_latitude']?.toString() ?? '',
                  );
                  longitude = double.tryParse(
                    zone['center_longitude']?.toString() ?? '',
                  );
                }
              }
            }
          } catch (profileError) {
            // Last resort: If we still have no coordinates but are going online,
            // we'll try to let the backend handle it or fail there.
          }
        }

        // Final validation before sending to API
        if (latitude == null || longitude == null) {
          // If we still don't have coordinates, we can't accurately report location,
          // but we try one last time with a shorter timeout or just fail.
          emit(
            DeliveryBoyStatusError(
              'Unable to get your current location. Please check your GPS and try again.',
              isOnline: false,
              isVerified: state.isVerified,
            ),
          );
          _isProcessing = false;
          return;
        }

        await Global.refreshCachedToken();

        if (Global.userToken == null || Global.userToken!.isEmpty) {
          emit(
            DeliveryBoyStatusError(
              'Authentication token is missing. Please login again.',
              isOnline: state.isOnline,
            ),
          );
          _isProcessing = false;
          return;
        }

        final response = await _deliveryBoyStatusRepo.updateDeliveryBoyStatus(
          isOnline: true,
          latitude: latitude,
          longitude: longitude,
        );

        if (response['success'] == true) {
          // Start location services in background (don't wait for it)
          _startLocationServicesInBackground();

          emit(
            DeliveryBoyStatusLoaded(
              isOnline: true,
              message: response['message'] ?? 'Status updated successfully',
            ),
          );
          await Global.setDeliveryBoyStatus(true);
        } else {
          emit(
            DeliveryBoyStatusError(
              response['message'] ?? 'Failed to update status',
              isOnline: state.isOnline, // Keep current status on failure
              isVerified: state.isVerified,
            ),
          );
        }
      } else {
        await Global.refreshCachedToken();

        if (Global.userToken == null || Global.userToken!.isEmpty) {
          emit(
            DeliveryBoyStatusError(
              'Authentication token is missing. Please login again.',
              isOnline: state.isOnline,
            ),
          );
          _isProcessing = false;
          return;
        }

        final response = await _deliveryBoyStatusRepo.updateDeliveryBoyStatus(
          isOnline: false,
        );

        if (response['success'] == true) {
          // Stop location services in background (don't wait for it)
          _stopLocationServicesInBackground();

          emit(
            DeliveryBoyStatusLoaded(
              isOnline: false,
              message: response['message'] ?? 'Status updated successfully',
            ),
          );
          await Global.setDeliveryBoyStatus(false);
        } else {
          emit(
            DeliveryBoyStatusError(
              response['message'] ?? 'Failed to update status',
              isOnline: state.isOnline, // Keep current status on failure
              isVerified: state.isVerified,
            ),
          );
        }
      }
    } catch (e) {
      emit(
        DeliveryBoyStatusError(
          'Failed to update status: ${e.toString()}',
          isOnline: state.isOnline,
          isVerified: state.isVerified,
        ),
      );
    } finally {
      _isProcessing = false;
    }
  }

  // Helper method to start location services in background
  void _startLocationServicesInBackground() {
    Future.microtask(() async {
      try {
        _locationTracker.startTracking();
      } catch (e) {
        //
      }
    });
  }

  // Helper method to stop location services in background
  void _stopLocationServicesInBackground() {
    Future.microtask(() async {
      try {
        _locationTracker.stopTracking();
      } catch (e) {
        //
      }
    });
  }
}
