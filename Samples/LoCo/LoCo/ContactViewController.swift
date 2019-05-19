//
//  ContactViewController.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import LLVS

class ContactViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    @IBOutlet weak var detailDescriptionLabel: UILabel?
    
    var contactBook: ContactBook?
    var contactIdentifier: Value.Identifier?
    
    @IBOutlet weak var firstNameField: UITextField!
    @IBOutlet weak var secondNameField: UITextField!
    @IBOutlet weak var streetAddressField: UITextField!
    @IBOutlet weak var postCodeField: UITextField!
    @IBOutlet weak var cityField: UITextField!
    @IBOutlet weak var countryField: UITextField!
    @IBOutlet weak var emailField: UITextField!
    @IBOutlet weak var phoneNumberField: UITextField!
    @IBOutlet weak var avatarButton: UIButton!
    
    private var shouldUpdateAvatar: Bool = false
    
    private var didSyncChangesObserver: AnyObject?
    
    private var contact: Contact? {
        guard let book = contactBook, let identifier = contactIdentifier else { return nil }
        return book.contacts.first(where: { $0.valueIdentifier == identifier })?.value
    }
    
    deinit {
        if let o = didSyncChangesObserver {
            NotificationCenter.default.removeObserver(o)
            didSyncChangesObserver = nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        didSyncChangesObserver = NotificationCenter.default.addObserver(forName: .contactBookDidSaveSyncChanges, object: contactBook, queue: .main) { notif in
            self.updateView()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateView()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        extractContactFromView()
    }
    
    func showContact(at index: Int, in book: ContactBook) {
        contactBook = book
        contactIdentifier = contactBook!.contacts[index].valueIdentifier
        updateView()
    }

    func updateView() {
        guard let _ = firstNameField else { return }
        shouldUpdateAvatar = false
        if let contact = contact {
            firstNameField.text = contact.person?.firstName
            secondNameField.text = contact.person?.secondName
            streetAddressField.text = contact.address?.streetAddress
            postCodeField.text = contact.address?.postCode
            cityField.text = contact.address?.city
            countryField.text = contact.address?.country
            emailField.text = contact.email
            phoneNumberField.text = contact.phoneNumber
            avatarButton.setImage(contact.avatarJPEGData.flatMap({ UIImage(data: $0) }), for: .normal)
        } else {
            firstNameField.text = nil
            secondNameField.text = nil
            streetAddressField.text = nil
            postCodeField.text = nil
            cityField.text = nil
            countryField.text = nil
            emailField.text = nil
            phoneNumberField.text = nil
            avatarButton.setImage(nil, for: .normal)
        }
    }
    
    func extractContactFromView() {
        guard let _ = firstNameField, let contact = contact else { return }
        
        var newContact = contact
        
        let firstName = firstNameField.text
        let secondName = secondNameField.text
        let person = firstName.flatMap { Person(firstName: $0, secondName: secondName) }
        newContact.person = person
        
        let streetAddress = streetAddressField.text
        let postCode = postCodeField.text
        let city = cityField.text
        let country = countryField.text
        let address = streetAddress.flatMap {
            Address(streetAddress: $0, postCode: postCode, city: city, country: country)
        }
        newContact.address = address
        
        newContact.email = emailField.text
        newContact.phoneNumber = phoneNumberField.text
        
        if shouldUpdateAvatar {
            newContact.avatarJPEGData = avatarButton.backgroundImage(for: .normal)?.jpegData(compressionQuality: 0.8)
        } else {
            newContact.avatarJPEGData = contact.avatarJPEGData
        }
        
        try! contactBook?.update(newContact)
    }
    
    
    // MARK: Avatar
    
    @IBAction func chooseAvatar(_ sender: Any) {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        picker.modalPresentationStyle = .fullScreen
        present(picker, animated: true, completion: nil)
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        self.dismiss(animated: true) {
            let image = (info[.editedImage] ?? info[.originalImage]) as! UIImage
            let scaledImage = image.scaledImage(withMaximumDimension: 300.0)
            self.avatarButton.setImage(scaledImage, for: .normal)
            self.shouldUpdateAvatar = true
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.dismiss(animated: true, completion: nil)
    }
}


extension UIImage {
    
    func scaledImage(withMaximumDimension maxDimension: CGFloat) -> UIImage {
        let scaleFactor = min(maxDimension / size.width, maxDimension / size.height)
        let scaledSize = CGSize(width: size.width*scaleFactor, height: size.height*scaleFactor)
        UIGraphicsBeginImageContextWithOptions(scaledSize, false, 1)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(x: 0.0, y: 0.0, width: scaledSize.width, height: scaledSize.height))
        return UIGraphicsGetImageFromCurrentImageContext()!
    }
    
}
