import 'package:equatable/equatable.dart';

abstract class ItemsCollectedState extends Equatable {
  @override
  List<Object?> get props => [];
}

class ItemsCollectedInitial extends ItemsCollectedState {}

class ItemsCollectedLoading extends ItemsCollectedState {
  final String itemId;
  ItemsCollectedLoading(this.itemId);

  @override
  List<Object?> get props => [itemId];
}

class ItemsCollectedSuccess extends ItemsCollectedState {
  final String message;
  final String itemId;

  ItemsCollectedSuccess(this.message, this.itemId);

  @override
  List<Object> get props => [message, itemId];
}

class ItemsCollectedError extends ItemsCollectedState {
  final String errorMessage;
  final String itemId;

  ItemsCollectedError(this.errorMessage, this.itemId);

  @override
  List<Object> get props => [errorMessage, itemId];
}
