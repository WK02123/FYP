import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LocationSearchPage extends StatefulWidget {
  final String title;

  /// Optional: when searching destination, pass the chosen origin to filter results.
  final String? originFilter;

  const LocationSearchPage({
    super.key,
    required this.title,
    this.originFilter,
  });

  @override
  State<LocationSearchPage> createState() => _LocationSearchPageState();
}

class _LocationSearchPageState extends State<LocationSearchPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _isOriginMode =>
      widget.title.toLowerCase().contains('origin'); // infer from title

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Build list of origins or destinations from routes collection.
  /// routes doc.id is expected to be "Origin|Destination"
  List<String> _buildItemsFromRoutes(QuerySnapshot snap) {
    final set = <String>{};

    for (final d in snap.docs) {
      final id = d.id.trim();
      final parts = id.split('|');
      if (parts.length != 2) continue;

      final origin = parts[0].trim();
      final dest = parts[1].trim();

      if (_isOriginMode) {
        set.add(origin);
      } else {
        // Destination mode
        if (widget.originFilter != null &&
            widget.originFilter!.trim().isNotEmpty) {
          // only destinations reachable from selected origin
          if (origin.toLowerCase() ==
              widget.originFilter!.trim().toLowerCase()) {
            set.add(dest);
          }
        } else {
          // list all unique destinations from all routes
          set.add(dest);
        }
      }
    }

    // search filter (case-insensitive)
    final list = set.where((s) => s.toLowerCase().contains(_query)).toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 🔴 Red Header
          Container(
            width: double.infinity,
            height: 120,
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 🔍 Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Type to search location',
                prefixIcon: Icon(Icons.search),
                filled: true,
                fillColor: Color(0xFFF5F5F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(15)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              "Available Locations",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),

          // Live list from Firestore (routes)
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('routes')
                  .snapshots(), // live updates
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No routes found'));
                }

                final items = _buildItemsFromRoutes(snapshot.data!);
                if (items.isEmpty) {
                  return const Center(child: Text('No matching locations'));
                }

                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final label = items[index];
                    return ListTile(
                      leading: const Icon(Icons.location_on),
                      title: Text(label),
                      onTap: () => Navigator.pop(context, label),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
